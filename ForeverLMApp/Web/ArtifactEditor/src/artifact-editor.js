import { HighlightStyle, syntaxHighlighting } from '@codemirror/language'
import { EditorView as CodeEditorView } from '@codemirror/view'
import { tags as codeTags } from '@lezer/highlight'
import { Crepe } from '@milkdown/crepe'
import { imageBlockSchema } from '@milkdown/kit/component/image-block'
import { linkPreviewTooltip, linkTooltipAPI } from '@milkdown/kit/component/link-tooltip'
import { commandsCtx, editorStateOptionsCtx, editorViewCtx, editorViewOptionsCtx, inputRulesCtx, parserCtx, schemaCtx, serializerCtx } from '@milkdown/kit/core'
import {
  addBlockTypeCommand,
  blockquoteSchema,
  bulletListSchema,
  codeBlockSchema,
  emphasisSchema,
  headingSchema,
  hrSchema,
  inlineCodeSchema,
  isMarkSelectedCommand,
  isNodeSelectedCommand,
  listItemSchema,
  orderedListSchema,
  paragraphSchema,
  selectTextNearPosCommand,
  setBlockTypeCommand,
  strongSchema,
  toggleEmphasisCommand,
  toggleInlineCodeCommand,
  toggleStrongCommand,
  wrapInBlockTypeCommand,
} from '@milkdown/kit/preset/commonmark'
import { addRowAfterCommand, createTable, footnoteDefinitionSchema, footnoteReferenceSchema, selectRowCommand, strikethroughSchema, tableSchema, toggleStrikethroughCommand } from '@milkdown/kit/preset/gfm'
import { trailingConfig } from '@milkdown/kit/plugin/trailing'
import { nodeRule } from '@milkdown/kit/prose'
import { lift, setBlockType } from '@milkdown/kit/prose/commands'
import { closeHistory } from '@milkdown/kit/prose/history'
import { inputRules, wrappingInputRule } from '@milkdown/kit/prose/inputrules'
import { liftListItem } from '@milkdown/kit/prose/schema-list'
import { DOMSerializer, Fragment, Slice } from '@milkdown/kit/prose/model'
import { Plugin, PluginKey, Selection, TextSelection } from '@milkdown/kit/prose/state'
import { Mapping, Transform } from '@milkdown/kit/prose/transform'
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view'
import { $inputRule, $prose, $remark, replaceAll } from '@milkdown/kit/utils'
import '@milkdown/crepe/theme/common/style.css'
import '@milkdown/crepe/theme/frame.css'
import './artifact-editor.css'
import foreverLMMarkURL from './foreverlm-mark.png'
import {
  blockEmbed,
  blockReference,
  dailyNoteID,
  dayKeyFromTitle,
  daysForQuery,
  dayTitle,
  embeddedBlockID,
  graphTokens,
  isBlockID,
  newBlockID,
  normalizedTitle,
  relativeDayKey,
  takeBlockIDMarker,
} from './notes-graph-syntax.js'
import { attachBlockProperties, defaultProperties, highlightHex, properties as blockPropertyValues, propertyComment } from './block-properties.js'
import { remarkMoneyIsNotMath } from './dollar-math.js'
import { remarkJoinedGrounding } from './joined-grounding.js'
import { citationFootnote, footnoteKey, freshNumericLabel, planFootnotes } from './footnotes.js'
import { joinPastedLines, mayBePrintedLines, pastedLines, writtenSpan } from './pasted-lines.js'
import { aliasedAddresses, isAddressStandIn, markedWordChanges, newAddressAliases, restoredAddresses, wordsOfDOM } from './ai-edit-proposal.js'
import { renderInline, renderMarkdown } from './notes-markdown.js'
import {
  closeNotesPanels,
  connectNotesGraph,
  fillBlockReferences,
  followSnippetLink,
  refreshFoot,
  scheduleReferencePreview,
  scheduleReferencePreviewHide,
  setFootDaily,
  setFootReferences,
  showBlockMenu,
  toggleBlockReferences,
} from './notes-graph.js'

let editor = null
let applyingExternalMarkdown = false
let lastMarkdown = ''
let userHasInteracted = false
let hasUserChanges = false
let currentSelection = null
let selectionButton = null
let selectionDropLayer = null
let collapsedSectionKeys = new Set()
let foldRefreshFrame = null
let foldPositionRefreshFrame = null
let foldStyle = null
let foldControls = null
let documentTabs = null
let activeDocumentTabKey = 'document'

// Milkdown's link mark sanitizes a non-web scheme out of the rendered `href`,
// but keeps the mark's own attribute and serializes that verbatim, so the
// Markdown is never what is at risk. What needs a web URL is the DOM, because
// that is where the grounding styling and the publication rewrite read a
// passage's sources from. Use a private HTTPS representation inside the editor
// and translate it back at the Markdown boundary, leaving Milkdown's
// sanitization intact. `.invalid` is reserved by RFC 2606 and can never be
// delegated, so a stand-in that escapes cannot become a request.
//
// A source a sentence named in its own words — a titled chip drawn into the
// prose — is the retired half of this. Nothing writes one any more: a source
// belongs to the passage that stands on it, not to the words of the sentence.
// The address is still read, because a doc written before that stays readable
// and is converted to grounding the first time it opens. A source link that
// stands alone on a line is something else: a source card, the shape a chat's
// Sources row has, drawn by the reference-card rule below and written by a
// drop that lands off the prose.
const sourceMarkdownPrefix = 'foreverlm://source/'
const sourceEditorPrefix = 'https://foreverlm.invalid/source/'
// Sources attached to a passage rather than named in it. The address carries the
// whole list, so "what does this sentence stand on" is answered by the passage
// itself and survives every edit that moves the passage.
const groundingMarkdownPrefix = 'foreverlm://grounding/'
const groundingEditorPrefix = 'https://foreverlm.invalid/grounding/'
const attachmentMarkdownPrefix = 'foreverlm://attachment/'
const attachmentEditorPrefix = 'https://foreverlm.invalid/attachment/'
// A link to one of the app's own things (another doc, a notebook or an Idea)
// is the one private address that is a destination: `foreverlm://doc/<id>`,
// `foreverlm://notebook/<id>` and `foreverlm://idea/<id>`
// (`foreverlm://project/<id>`, the address a notebook had before the word
// changed, is still read; nothing writes it). The host follows it; the editor
// only has to keep the address intact and offer a way to follow it.
const inAppLinkKinds = new Map([
  ['doc', { open: 'Open page' }],
  ['notebook', { open: 'Open notebook' }],
  ['project', { open: 'Open notebook' }],
  ['idea', { open: 'Open idea' }],
  ['chat', { open: 'Open chat' }],
])
const markdownSchemePrefix = 'foreverlm://'
const editorSchemePrefix = 'https://foreverlm.invalid/'
let attachmentDataURLs = new Map()
let attachmentStorageURLs = new Map()
let inAppLinkTooltip = null
let inAppLinkTooltipHovered = false

/// Rewrite every Markdown link and image target through `rewrite`, and nothing
/// else in the document.
///
/// Both translations below used to be a blind replacement across the whole
/// string, which also caught text that merely mentioned one of these prefixes:
/// a note documenting the scheme came back from a save with its own example
/// rewritten. A target only ever follows the `](` that closes a link's text, so
/// anchoring the match there leaves prose and code spans alone. Reference-style
/// definitions are not a target this editor ever writes.
function rewriteTargets(markdown, rewrite) {
  return String(markdown ?? '').replace(
    /(\]\(\s*<?)([^\s)>]+)/g,
    (_match, opening, target, offset, whole) => `${opening}${rewrite(target, closesPicture(whole, offset))}`
  )
}

/// Whether the `]` at `closeIndex` closes the description of a picture,
/// `![…]`, rather than the text of a link: a file's link names an attachment
/// too, and it is not drawn from the attachment's data.
function closesPicture(text, closeIndex) {
  let depth = 0
  for (let index = closeIndex; index >= 0; index -= 1) {
    const character = text[index]
    if (text[index - 1] === '\\') continue
    if (character === ']') depth += 1
    else if (character === '[') {
      depth -= 1
      if (depth === 0) return text[index - 1] === '!'
    }
  }
  return false
}

function swapPrefix(value, from, to) {
  return value.startsWith(from) ? `${to}${value.slice(from.length)}` : value
}

/// Every `foreverlm://<kind>/…` address takes the same private HTTPS shape
/// inside the editor — sources, grounding, attachments, docs and notebooks alike
/// — so a kind added later needs no new translation. `swapPrefix` keeps the
/// scheme-only case (`foreverlm://` with nothing after it) as it was.
function editorAddress(target) {
  return /^foreverlm:\/\/[a-z-]+\//i.test(target)
    ? swapPrefix(target, markdownSchemePrefix, editorSchemePrefix)
    : target
}

function storageAddress(target) {
  return /^https:\/\/foreverlm\.invalid\/[a-z-]+\//i.test(target)
    ? swapPrefix(target, editorSchemePrefix, markdownSchemePrefix)
    : target
}

function markdownForEditor(markdown) {
  return rewriteTargets(graphParsableMarkdown(markdown), (target, isPicture) => {
    const editorURL = editorAddress(target)
    // A picture is drawn from the data URL the host handed over; the
    // identity above is the only part the document keeps. A link to an
    // attached file keeps its address: a data URL is not one a link can hold,
    // and the host hands over data for every attachment the page names.
    return isPicture ? (attachmentDataURLs.get(editorURL) ?? editorURL) : editorURL
  })
}

function markdownForStorage(markdown) {
  return graphReadableMarkdown(rewriteTargets(markdown, (target) => storageAddress(attachmentStorageURLs.get(target) ?? target)))
}

// ─── The notes grammar at the Markdown boundary ────────────────────────────
// Milkdown's serializer escapes what CommonMark might read as markup, and the
// grammar's readers (`DocGraphSyntax`, the host's graph, MCP) take two of
// those escapes as written: `\[\[Title]]` and a line-leading `\#tag`. Three
// others would hide a piece of the grammar from them, so they are taken back
// here, where each is still exactly the text it was (nothing below changes
// how CommonMark reads the line):
//
// - `[[Title]]((a1b2c3d4e))`: a `(` straight after `]` is escaped, which would
//   leave the reference unreadable. Without the escape the text still reads
//   as text, because every `[` in prose is escaped and so no `]` here closes
//   a link.
// - `{{[[embed]]: ((a1b2c3d4e))}}`, Roam's own embed, keeps its brackets.
// - `#snake_case`: an underscore inside a tag is escaped; between two letters
//   or digits it can never open or close emphasis, so it is written plain.
//
// And one the other way: a Markdown writer that puts a reference straight
// after a closing bracket, `[[Title]]((a1b2c3d4e))`, wrote what CommonMark
// reads as a link whose address is `(a1b2c3d4e)`; the editor escapes the
// parenthesis before parsing so the words arrive as the reference they are.
// Code spans and fenced code are left alone throughout: nothing in code is
// grammar.

function outsideCode(markdown, transform) {
  let fence = null
  return String(markdown ?? '').split('\n').map((line) => {
    const opening = /^\s*(`{3,}|~{3,})/.exec(line)
    if (fence) {
      if (opening && opening[1][0] === fence[0] && opening[1].length >= fence.length && /^\s*[`~]+\s*$/.test(line)) fence = null
      return line
    }
    if (opening) {
      fence = opening[1]
      return line
    }
    if (!/[[\]#({\\]/.test(line)) return line
    return line.split(/(`+[^`]*`+)/).map((part, index) => (index % 2 === 1 ? part : transform(part))).join('')
  }).join('\n')
}

const escapedReferenceAfterBracket = /(?<=\])\\\(\(([a-z0-9]{9})\)\)/g
const escapedRoamEmbed = /\{\{(\s*)\\\[\\\[embed\\?\]\\?\](\s*:)/g
const tagWithEscapedUnderscore = /(^|[\s(])(\\?#)((?:[\p{L}\p{N}\-/_]|\\_)+)/gu
const referenceAfterBracket = /(?<=\])\(\(([a-z0-9]{9})\)\)/g

function graphReadableMarkdown(markdown) {
  return outsideCode(markdown, (text) => text
    .replace(escapedReferenceAfterBracket, '(($1))')
    .replace(escapedRoamEmbed, '{{$1[[embed]]$2')
    .replace(tagWithEscapedUnderscore, (_match, before, hash, body) => (
      `${before}${hash}${body.replace(/(?<=[\p{L}\p{N}])\\_(?=[\p{L}\p{N}])/gu, '_')}`
    )))
}

function graphParsableMarkdown(markdown) {
  return outsideCode(markdown, (text) => text.replace(referenceAfterBracket, '\\(($1))'))
}

/// The doc or notebook an editor href points at — `{ kind, id, href }` with the
/// stored `foreverlm://` form of the address — or null for any other link.
function inAppLink(href) {
  try {
    const url = new URL(String(href ?? ''))
    let kind
    let id
    if (url.protocol.toLowerCase() === 'https:' && url.hostname.toLowerCase() === 'foreverlm.invalid') {
      const parts = url.pathname.split('/').filter(Boolean)
      kind = parts[0]?.toLowerCase()
      id = parts[1]
    } else if (url.protocol.toLowerCase() === 'foreverlm:') {
      kind = url.hostname.toLowerCase()
      id = url.pathname.split('/').filter(Boolean)[0]
    }
    if (!kind || !inAppLinkKinds.has(kind) || !id) return null
    if (kind === 'project') kind = 'notebook'
    return { kind, id: decodeURIComponent(id), href: `${markdownSchemePrefix}${kind}/${id}` }
  } catch {
    return null
  }
}

function isPrivateAddress(href) {
  return String(href ?? '').toLowerCase().startsWith(editorSchemePrefix)
}

function post(type, detail = {}) {
  const message = { type, ...detail }
  if ((type === 'markdownChanged' || type === 'saveRequested') && typeof detail.markdown === 'string') {
    rememberReportedMarkdown(detail.markdown)
  }
  if (window.webkit?.messageHandlers?.artifactEditor) {
    window.webkit.messageHandlers.artifactEditor.postMessage(message)
  } else {
    window.parent?.postMessage({ source: 'foreverLMArtifactEditor', ...message }, window.location.origin)
  }
}

function sourceID(href) {
  try {
    const url = new URL(href)
    const isNativeSource = url.protocol.toLowerCase() === 'foreverlm:' && url.hostname.toLowerCase() === 'source'
    const isEditorSource = url.protocol.toLowerCase() === 'https:' && url.hostname.toLowerCase() === 'foreverlm.invalid' && url.pathname.startsWith('/source/')
    if (!isNativeSource && !isEditorSource) {
      return null
    }
    const path = isEditorSource ? url.pathname.slice('/source/'.length) : url.pathname.replace(/^\//, '')
    const token = decodeURIComponent(path).trim()
    return token || null
  } catch {
    return null
  }
}

/// The sources a grounding address carries, in the order they were attached.
///
/// Returns an empty list for every other kind of link, which is what keeps a
/// source chip, an ordinary web link, and a grounded passage distinguishable
/// everywhere one link mark has to stand for all three.
function groundingSourceIDs(href) {
  try {
    const url = new URL(href)
    const isNative = url.protocol.toLowerCase() === 'foreverlm:'
      && url.hostname.toLowerCase() === 'grounding'
    const isEditor = url.protocol.toLowerCase() === 'https:'
      && url.hostname.toLowerCase() === 'foreverlm.invalid'
      && url.pathname.startsWith('/grounding/')
    if (!isNative && !isEditor) return []
    const path = isEditor
      ? url.pathname.slice('/grounding/'.length)
      : url.pathname.replace(/^\//, '')
    const ordered = []
    const seen = new Set()
    for (const part of path.split(',')) {
      let token = ''
      try {
        token = decodeURIComponent(part).trim()
      } catch {
        token = part.trim()
      }
      if (!token || seen.has(token)) continue
      seen.add(token)
      ordered.push(token)
    }
    return ordered
  } catch {
    return []
  }
}

/// The address that carries a passage's attached sources.
function groundingHref(sourceIDs) {
  return `${groundingEditorPrefix}${sourceIDs.map((id) => encodeURIComponent(id)).join(',')}`
}

/// Whether a link mark is one of the editor's own source addresses — a chip or a
/// grounded passage — rather than a link to somewhere on the web.
function isSourceAddress(href) {
  return Boolean(sourceID(href)) || groundingSourceIDs(href).length > 0
}

function currentMarkdown() {
  if (!hasUserChanges) return lastMarkdown
  return markdownForStorage(editor?.getMarkdown() ?? lastMarkdown)
}

function publicationHTML(title = 'Untitled Article') {
  const root = document.querySelector('.milkdown .editor')
  if (!root) return ''
  // Every reference and embed is drawn for the copy, the one the caret is in
  // as well: a reader outside the app gets the words, never `((id))`.
  const article = withEveryReferenceDrawn(() => root.cloneNode(true))
  publishedGraphWords(article)
  article.removeAttribute('contenteditable')
  article.removeAttribute('spellcheck')
  for (const element of article.querySelectorAll('[contenteditable], [data-placeholder]')) {
    element.removeAttribute('contenteditable')
    element.removeAttribute('data-placeholder')
  }
  // A private address is an in-app identity, not a destination a reader
  // outside the app can follow: left in place it would publish a link to a
  // host that can never resolve. The words stay, the anchor goes. Grounding
  // covers ordinary prose, so this unwraps rather than replaces — a passage's
  // sentences are not a citation — and a doc or Notebook link keeps its title.
  for (const anchor of article.querySelectorAll('a[href^="https://foreverlm.invalid/"]')) {
    anchor.replaceWith(...anchor.childNodes)
  }
  // A reference card's control and a paragraph's margin cards are the
  // library's answer to this Mac, not part of the writing; the titles and
  // their links stay.
  for (const control of article.querySelectorAll('.artifact-reference-control, .artifact-reference-thumbnail, .artifact-reference-meta, .artifact-margin-cards')) {
    control.remove()
  }
  // A Prompt's button and a visualization's frame are what this editor draws
  // for the writer. A published page has no Chat to open and its policy runs no
  // inline script, so both go; where a visualization was, the page says so
  // rather than publishing a program as a block of code.
  for (const widget of article.querySelectorAll('.artifact-callout-chat, .artifact-visualization')) {
    widget.remove()
  }
  // A table is its rows alone: the handles, the add buttons and the drag
  // preview are this editor's. Its width and column fit stay, as classes the
  // published stylesheet below draws (Block properties).
  for (const block of article.querySelectorAll('.milkdown-table-block')) {
    const rows = block.querySelector('tbody.content-dom')
    const plain = document.createElement('div')
    plain.className = 'table-block'
    if (block.dataset.tableWidth) plain.classList.add(`table-${block.dataset.tableWidth}`)
    if (block.dataset.tableFit) plain.classList.add(`table-${block.dataset.tableFit}`)
    const table = document.createElement('table')
    if (rows) table.append(rows)
    plain.append(table)
    block.replaceWith(plain)
  }
  // The editor's copy-and-paste form of the properties is not the page's.
  for (const element of article.querySelectorAll('[data-fl-width], [data-fl-fit], [data-fl-color]')) {
    element.removeAttribute('data-fl-width')
    element.removeAttribute('data-fl-fit')
    element.removeAttribute('data-fl-color')
  }
  for (const source of article.querySelectorAll('.artifact-viz-source')) {
    const note = document.createElement('p')
    note.innerHTML = '<em>An interactive visualization appears here in ForeverLM.</em>'
    source.replaceWith(note)
  }
  publishedFootnotes(article)
  const escape = (value) => String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character])
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escape(title)}</title><style>
:root{color-scheme:light dark}body{margin:0;background:#fff;color:#171717;font:19px/1.7 ui-serif,Georgia,Cambria,"Times New Roman",serif}article{max-width:720px;margin:0 auto;padding:72px 28px 120px}h1,h2,h3,h4{font-family:ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;line-height:1.18;margin:2em 0 .65em}h1{font-size:2.6em;margin-top:0}h2{font-size:1.65em}p{margin:1.1em 0}blockquote{margin:1.5em 0;padding-left:1.2em;border-left:3px solid #bbb;color:#555}img{display:block;max-width:100%;height:auto;margin:2em auto;border-radius:8px}pre{overflow:auto;padding:1em;border-radius:8px;background:#f4f4f4}code{font:.84em ui-monospace,SFMono-Regular,Menlo,monospace}a{color:inherit;text-decoration-thickness:.08em;text-underline-offset:.16em}cite{font-style:normal;text-decoration:underline;text-decoration-style:dotted}hr{border:0;border-top:1px solid #ddd;margin:3em 0}${publishedBlockPropertyStyles()}${publishedFootnoteStyles}@media(prefers-color-scheme:dark){body{background:#171717;color:#eee}blockquote{color:#bbb}pre{background:#252525}section.footnotes{border-top-color:#333;color:#bbb}}
</style></head><body><article>${article.innerHTML}</article></body></html>`
}

/// A copy's footnotes, as the site publishes them (docs-site/website/publishing/
/// markdown.ts): each number a link to its note, `<sup class="fn-ref">`, and the
/// notes a numbered list under the article that links back to the first
/// number. The numbers are the ones the page shows (`data-n`), since the
/// label the Markdown keeps may be a name.
function publishedFootnotes(article) {
  const references = [...article.querySelectorAll('sup.artifact-footnote-ref')]
  const notes = [...article.querySelectorAll('div.artifact-footnote')]
  if (!references.length && !notes.length) return
  const cited = new Map()
  for (const reference of references) {
    const number = Number(reference.dataset.n)
    if (!Number.isInteger(number) || number < 1) {
      reference.remove()
      continue
    }
    const count = (cited.get(number) ?? 0) + 1
    cited.set(number, count)
    const sup = document.createElement('sup')
    sup.className = 'fn-ref'
    const link = document.createElement('a')
    link.href = `#fn-${number}`
    link.id = count === 1 ? `fnref-${number}` : `fnref-${number}-${count}`
    link.textContent = String(number)
    sup.append(link)
    reference.replaceWith(sup)
  }
  const list = document.createElement('ol')
  const ordered = notes
    .map((note) => ({ note, number: Number(note.dataset.n) }))
    .filter(({ number }) => Number.isInteger(number) && number > 0)
    .sort((left, right) => left.number - right.number)
  for (const { note, number } of ordered) {
    const item = document.createElement('li')
    item.id = `fn-${number}`
    item.value = number
    item.append(...(note.querySelector('.artifact-footnote-body')?.childNodes ?? []))
    if (cited.has(number)) {
      const back = document.createElement('a')
      back.className = 'fn-back'
      back.href = `#fnref-${number}`
      back.setAttribute('aria-label', 'Back to the text')
      back.textContent = '↩'
      const last = item.lastElementChild
      if (last?.tagName === 'P') last.append(' ', back)
      else item.append(back)
    }
    list.append(item)
  }
  for (const note of notes) note.remove()
  if (!list.childElementCount) return
  const section = document.createElement('section')
  section.className = 'footnotes'
  section.setAttribute('aria-label', 'Notes')
  section.append(list)
  article.append(section)
}

const publishedFootnoteStyles = 'sup.fn-ref{font:600 .7em/0 ui-sans-serif,-apple-system,BlinkMacSystemFont,sans-serif}sup.fn-ref a{padding:0 .12em;text-decoration:none}section.footnotes{margin:3.4em 0 0;padding-top:1.2em;border-top:1px solid #ddd;color:#555;font-size:.86em}section.footnotes ol{margin:0;padding-left:1.6em}section.footnotes li{margin:.4em 0}section.footnotes li p{margin:.3em 0}a.fn-back{margin-left:.2em;text-decoration:none}'

/// The rules a published copy draws block properties by: a table's width and
/// column fit, a highlight's colour. A table at its defaults and a yellow
/// highlight carry no class or attribute, so these only say what was chosen.
function publishedBlockPropertyStyles() {
  const colors = Object.entries(highlightHex).filter(([name]) => name !== 'yellow')
    .map(([name, hex]) => `blockquote[data-callout="highlight"][data-callout-color="${name}"]{--hl:${hex}}`).join('')
  return `.table-block{margin:1.4em 0}.table-block.table-flexible{overflow-x:auto}.table-flexible table{width:max-content}.table-block.table-full{box-sizing:border-box;width:100vw;margin-left:calc(50% - 50vw);padding:0 28px}.table-even table{table-layout:fixed;width:100%}blockquote[data-callout="highlight"]{--hl:${highlightHex.yellow};padding:.55em 1em;border-left-color:var(--hl);border-radius:8px;background:color-mix(in srgb,var(--hl) 13%,transparent);color:inherit}${colors}`
}

/// The published copy carries the notes graph's words, not its grammar: a
/// reference reads as its block's words, an embed as its block, a title link
/// as its title; the typed forms, the ids, a reference nobody could answer and
/// the reference counts are not part of the writing.
function publishedGraphWords(article) {
  for (const paragraph of article.querySelectorAll('p.artifact-embed-paragraph')) {
    const body = paragraph.querySelector('.artifact-embed-body')
    if (!body) {
      paragraph.remove()
      continue
    }
    const block = document.createElement('div')
    block.className = 'embedded-block'
    block.append(...body.childNodes)
    paragraph.replaceWith(block)
  }
  const dropped = [
    '.artifact-graph-hidden',
    '.artifact-graph-source',
    '.artifact-embed-unresolved',
    '.artifact-block-ref.is-missing',
    '.artifact-block-ref-count',
    '.artifact-page-bracket',
  ].join(', ')
  for (const element of article.querySelectorAll(dropped)) element.remove()
  for (const reference of article.querySelectorAll('.artifact-block-ref')) {
    const words = document.createElement('span')
    words.append(...reference.childNodes)
    reference.replaceWith(words)
  }
  // A snippet's links are in-app addresses: their words stay.
  for (const anchor of article.querySelectorAll('a[data-href], a[data-title], a[data-source-id]')) {
    anchor.replaceWith(...anchor.childNodes)
  }
  for (const element of article.querySelectorAll('[data-block-id], [data-page-title], [contenteditable="false"]')) {
    element.removeAttribute('data-block-id')
    element.removeAttribute('data-page-title')
  }
}

/// An element's own words: its text without what decorations drew into it (a
/// reference count, a reference drawn as its block's words), so a heading's
/// title, and the fold kept by it, read as the heading as written.
function ownText(element) {
  let text = ''
  const walk = (node) => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) text += child.nodeValue
      else if (child.nodeType === Node.ELEMENT_NODE && !child.classList.contains('ProseMirror-widget')) walk(child)
    }
  }
  walk(element)
  return text
}

function sectionHeadings() {
  const root = document.querySelector('.milkdown .editor')
  if (!root) return []
  const occurrences = new Map()
  return [...root.children]
    .filter((element) => element.tagName === 'H2')
    .map((element) => {
      const title = ownText(element).trim() || 'Untitled section'
      const occurrence = occurrences.get(title) ?? 0
      occurrences.set(title, occurrence + 1)
      return { element, key: `${title}\u0000${occurrence}`, title }
    })
}

function ensureFoldStyle() {
  if (foldStyle) return foldStyle
  foldStyle = document.createElement('style')
  foldStyle.dataset.artifactSectionFolds = 'true'
  document.head.append(foldStyle)
  return foldStyle
}

function ensureDocumentTabs() {
  if (documentTabs) return documentTabs
  documentTabs = document.createElement('aside')
  documentTabs.className = 'artifact-document-tabs'
  documentTabs.setAttribute('aria-label', 'Document tabs')
  document.body.append(documentTabs)
  return documentTabs
}

function ensureFoldControls() {
  if (foldControls) return foldControls
  foldControls = document.createElement('div')
  foldControls.className = 'artifact-heading-fold-controls'
  foldControls.setAttribute('aria-label', 'Fold controls')
  document.body.append(foldControls)
  return foldControls
}

function uniqueDocumentTabTitle(markdown) {
  const existing = new Set(sectionHeadings().map(({ title }) => title.toLocaleLowerCase()))
  let title = 'Untitled tab'
  let suffix = 2
  while (existing.has(title.toLocaleLowerCase())) {
    title = `Untitled tab ${suffix}`
    suffix += 1
  }
  return title
}

function addDocumentTab() {
  if (!editor) return
  const title = uniqueDocumentTabTitle(currentMarkdown())
  const current = currentMarkdown()
  const separator = !current ? '' : current.endsWith('\n\n') ? '' : current.endsWith('\n') ? '\n' : '\n\n'
  const next = `${current}${separator}## ${title}\n\n`
  activeDocumentTabKey = `${title}\u00000`
  applyingExternalMarkdown = true
  userHasInteracted = true
  hasUserChanges = true
  lastMarkdown = next
  editor.editor.action(replaceAll(markdownForEditor(next)))
  post('markdownChanged', { markdown: next })
  requestAnimationFrame(() => {
    applyingExternalMarkdown = false
    refreshSectionFolds()
    const heading = sectionHeadings().find(({ key }) => key === activeDocumentTabKey)
    heading?.element.scrollIntoView({ block: 'start', behavior: 'smooth' })
    document.querySelector('.ProseMirror')?.focus()
  })
}

function renderDocumentTabs(headings) {
  const rail = ensureDocumentTabs()
  const header = document.createElement('header')
  const label = document.createElement('strong')
  label.textContent = 'Tabs'
  const add = document.createElement('button')
  add.type = 'button'
  add.className = 'artifact-document-tab-add'
  add.textContent = '+'
  add.title = 'Add tab'
  add.setAttribute('aria-label', 'Add tab')
  add.addEventListener('click', addDocumentTab)
  header.append(label, add)

  const items = [{ key: 'document', title: 'Document', element: null }, ...headings]
  if (!items.some(({ key }) => key === activeDocumentTabKey)) activeDocumentTabKey = 'document'
  const buttons = items.map(({ key, title, element }) => {
    const row = document.createElement('div')
    row.className = 'artifact-document-tab-row'
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'artifact-document-tab'
    button.classList.toggle('active', key === activeDocumentTabKey)
    button.setAttribute('aria-current', key === activeDocumentTabKey ? 'page' : 'false')
    const icon = document.createElement('span')
    icon.className = 'artifact-document-tab-icon'
    icon.setAttribute('aria-hidden', 'true')
    const copy = document.createElement('span')
    copy.textContent = title
    button.append(icon, copy)
    button.addEventListener('click', () => {
      activeDocumentTabKey = key
      renderDocumentTabs(sectionHeadings())
      if (element) element.scrollIntoView({ block: 'start', behavior: 'smooth' })
      else window.scrollTo({ top: 0, behavior: 'smooth' })
      document.querySelector('.ProseMirror')?.focus()
    })
    row.append(button)

    return row
  })
  const list = document.createElement('div')
  list.className = 'artifact-document-tab-list'
  list.append(...buttons)
  rail.replaceChildren(header, list)
}

function foldChevron() {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  svg.setAttribute('viewBox', '0 0 12 12')
  svg.setAttribute('aria-hidden', 'true')
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path')
  path.setAttribute('d', 'm3.75 4.75 2.25 2.5 2.25-2.5')
  svg.append(path)
  return svg
}

function toggleSectionFold(key) {
  if (collapsedSectionKeys.has(key)) collapsedSectionKeys.delete(key)
  else collapsedSectionKeys.add(key)
  refreshSectionFolds()
}

/// Keep the fold affordance beside the heading or bullet it controls. The
/// document outline disappears in narrow Studio panes, so putting the only
/// control in that rail made sections impossible to expand or collapse at
/// common widths. A chevron shows only while the pointer is on its line, or
/// while what it folds is folded, so the page reserves no rail for them
/// (docs/docs-design.md → "Folding a section or a bullet").
function renderFoldControls(headings = sectionHeadings()) {
  foldPositionRefreshFrame = null
  const controls = ensureFoldControls()
  const buttons = []

  for (const { element, key, title } of headings) {
    const collapsed = collapsedSectionKeys.has(key)
    const hovered = hoveredFoldTarget?.kind === 'section' && hoveredFoldTarget.key === key
    if (!collapsed && !hovered) continue
    const rect = element.getBoundingClientRect()
    if (rect.bottom < 0 || rect.top > window.innerHeight) continue
    const firstLineHeight = parseFloat(getComputedStyle(element).lineHeight) || rect.height
    const button = foldButton({
      collapsed,
      label: title,
      left: rect.left - 28,
      top: rect.top + Math.max(0, (firstLineHeight - 20) / 2),
      toggle: () => toggleSectionFold(key),
    })
    // What a right-click on the chevron is about (`blockMenuTarget`).
    button.dataset.foldSection = key
    buttons.push(button)
  }

  const view = foldEditorView()
  if (view) {
    const folded = new Set(outlineFoldPositions(view.state))
    const hoveredPos = hoveredFoldTarget?.kind === 'item' ? hoveredFoldTarget.pos : null
    for (const pos of new Set([...folded, ...(hoveredPos == null ? [] : [hoveredPos])])) {
      const node = view.state.doc.nodeAt(pos)
      if (!isFoldableListItem(node)) continue
      const label = listItemLabel(view, pos)
      if (!label) continue
      const rect = label.getBoundingClientRect()
      // A bullet inside a folded section or a folded bullet has no box.
      if (rect.width === 0 && rect.height === 0) continue
      if (rect.bottom < 0 || rect.top > window.innerHeight) continue
      const button = foldButton({
        collapsed: folded.has(pos),
        label: node.firstChild?.textContent.trim() || 'bullet',
        left: rect.left - 20,
        top: rect.top + (rect.height - 20) / 2,
        toggle: () => toggleOutlineFold(view, pos),
      })
      button.dataset.foldPos = String(pos)
      buttons.push(button)
    }
  }

  controls.replaceChildren(...buttons)
}

function foldButton({ collapsed, label, left, top, toggle }) {
  const fold = document.createElement('button')
  fold.type = 'button'
  fold.className = 'artifact-heading-fold'
  fold.classList.toggle('is-collapsed', collapsed)
  fold.append(foldChevron())
  fold.setAttribute('aria-label', `${collapsed ? 'Expand' : 'Collapse'} ${label}`)
  fold.setAttribute('aria-expanded', String(!collapsed))
  fold.style.left = `${Math.max(4, left)}px`
  fold.style.top = `${top}px`
  fold.addEventListener('pointerdown', (event) => event.preventDefault())
  fold.addEventListener('click', toggle)
  return fold
}

function scheduleFoldControlsRefresh() {
  if (foldPositionRefreshFrame != null) return
  foldPositionRefreshFrame = requestAnimationFrame(() => renderFoldControls())
}

function refreshSectionFolds() {
  foldRefreshFrame = null
  const headings = sectionHeadings()
  const currentKeys = new Set(headings.map(({ key }) => key))
  collapsedSectionKeys = new Set([...collapsedSectionKeys].filter((key) => currentKeys.has(key)))
  renderDocumentTabs(headings)

  const root = document.querySelector('.milkdown .editor')
  if (!root) {
    ensureFoldStyle().textContent = ''
    ensureFoldControls().replaceChildren()
    return
  }
  const children = [...root.children]
  const rules = []

  for (const { element, key } of headings) {
    if (!collapsedSectionKeys.has(key)) continue
    const headingIndex = children.indexOf(element)
    let finalIndex = headingIndex
    let sibling = element.nextElementSibling
    // A folded last section leaves the page's notes showing.
    while (sibling && sibling.tagName !== 'H1' && sibling.tagName !== 'H2' && sibling.dataset?.type !== 'footnote_definition') {
      finalIndex += 1
      sibling = sibling.nextElementSibling
    }
    if (finalIndex > headingIndex) {
      rules.push(`.milkdown .editor > :nth-child(n+${headingIndex + 2}):nth-child(-n+${finalIndex + 1}) { display: none !important; }`)
    }
    rules.push(`.milkdown .editor > h2:nth-child(${headingIndex + 1}) { margin-bottom: 0.5em; }`)
  }
  ensureFoldStyle().textContent = rules.join('\n')
  renderFoldControls(headings)
  // Folding hides paragraphs, and the stacks below them move up with the prose.
  scheduleMarginCardLayout()
  postFoldsIfChanged()
}

function scheduleSectionFoldRefresh() {
  if (foldRefreshFrame != null) return
  foldRefreshFrame = requestAnimationFrame(refreshSectionFolds)
}

// ─── Folding a bullet ───────────────────────────────────────────────────────
// A bullet with bullets under it folds them away, the way an outliner does:
// the chevron beside it, or ⌘↑ / ⌘↓ with the caret on its line. A fold is the
// position of the folded list item, carried through every edit by the
// transaction's mapping, so typing above it or inside it never loses it. The
// Markdown is untouched: a fold is how this reader looks at the doc, and the
// host keeps it per doc (`foldsChanged`, `setMarkdown`'s second argument).

const outlineFoldKey = new PluginKey('artifactOutlineFolds')

/// The editor's view once Crepe has finished creating it. Pointer, scroll and
/// resize handlers run from the first moment, before the view exists.
function foldEditorView() {
  if (!editor || !document.body.classList.contains('ready')) return null
  return activeEditorView()
}

function isFoldableListItem(node) {
  return node?.type.name === 'list_item' && node.childCount > 1
}

function outlineFoldPositions(state) {
  return outlineFoldKey.getState(state) ?? []
}

/// Where the hidden part of a folded item starts: after its own first line.
function outlineHiddenRange(node, pos) {
  return { from: pos + 1 + node.firstChild.nodeSize, to: pos + node.nodeSize - 1 }
}

const outlineFoldPlugin = $prose(() => new Plugin({
  key: outlineFoldKey,
  state: {
    init: () => [],
    apply(tr, folded, _oldState, newState) {
      const meta = tr.getMeta(outlineFoldKey)
      let next = folded
      if (tr.docChanged) {
        next = next.flatMap((pos) => {
          const mapped = tr.mapping.mapResult(pos, 1)
          return mapped.deletedAfter ? [] : [mapped.pos]
        })
      }
      if (meta?.set) next = meta.set
      if (meta?.toggle != null) {
        next = next.includes(meta.toggle)
          ? next.filter((pos) => pos !== meta.toggle)
          : [...next, meta.toggle]
      }
      // A caret the reader moves into hidden text — arrowing, find — opens
      // the fold that hid it. A fold laid over the caret moves the caret
      // instead (`appendTransaction`). Select All leaves its head at the
      // doc's end and the folds as they were.
      const { head } = newState.selection
      const caretMoved = tr.selectionSet && !meta
      const kept = [...new Set(next)].filter((pos) => {
        const node = newState.doc.nodeAt(pos)
        if (!isFoldableListItem(node)) return false
        if (!caretMoved) return true
        const hidden = outlineHiddenRange(node, pos)
        return head <= hidden.from || head >= hidden.to
      }).sort((a, b) => a - b)
      return kept.length === folded.length && kept.every((pos, index) => pos === folded[index]) ? folded : kept
    },
  },
  appendTransaction(transactions, _oldState, state) {
    if (!transactions.some((tr) => tr.getMeta(outlineFoldKey))) return null
    const { head } = state.selection
    // The outermost fold over the caret: the one whose line is on the page.
    for (const pos of outlineFoldPositions(state)) {
      const node = state.doc.nodeAt(pos)
      const hidden = outlineHiddenRange(node, pos)
      if (head <= hidden.from || head >= hidden.to) continue
      const lineEnd = pos + 2 + node.firstChild.content.size
      return state.tr.setSelection(TextSelection.create(state.doc, lineEnd)).setMeta('addToHistory', false)
    }
    return null
  },
  props: {
    decorations(state) {
      const folded = outlineFoldPositions(state)
      if (folded.length === 0) return null
      return DecorationSet.create(state.doc, folded.map((pos) => (
        Decoration.node(pos, pos + state.doc.nodeAt(pos).nodeSize, { class: 'is-outline-folded' })
      )))
    },
  },
  view: () => ({
    update(view, previous) {
      const foldsMoved = outlineFoldPositions(view.state) !== outlineFoldPositions(previous)
      if (!foldsMoved && view.state.doc === previous.doc) return
      scheduleFoldControlsRefresh()
      if (foldsMoved) scheduleMarginCardLayout()
      scheduleFoldPost()
    },
  }),
}))

function toggleOutlineFold(view, pos) {
  view.dispatch(view.state.tr.setMeta(outlineFoldKey, { toggle: pos }))
}

/// The list item's own bullet, number or checkbox — not one of its children's.
function listItemLabel(view, pos) {
  const block = view.nodeDOM(pos)
  return block?.querySelector?.(':scope > li > .label-wrapper') ?? null
}

/// The innermost list item the caret's line belongs to, when the caret is on
/// that item's own first line.
function listItemAtCaret(state) {
  const { $from } = state.selection
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    if ($from.node(depth).type.name !== 'list_item') continue
    if ($from.index(depth) !== 0) return null
    return { node: $from.node(depth), pos: $from.before(depth), depth }
  }
  return null
}

/// Return on a folded bullet's line starts the next bullet after everything it
/// folds, the way an outliner does. ProseMirror's split would hand the hidden
/// bullets to the new, unfolded one and spill them back onto the page. Text
/// after the caret moves into the new bullet, as a split would move it.
function splitFoldedListItem(view) {
  const { state } = view
  if (!state.selection.empty) return false
  const item = listItemAtCaret(state)
  if (!item || !outlineFoldPositions(state).includes(item.pos)) return false
  const { $from } = state.selection
  const line = $from.parent
  const rest = line.content.cut($from.parentOffset)
  const attrs = item.node.attrs.checked == null ? item.node.attrs : { ...item.node.attrs, checked: false }
  const next = item.node.type.create(attrs, line.type.create(line.attrs, rest))
  const insertAt = item.pos + item.node.nodeSize
  const tr = state.tr.insert(insertAt, next)
  tr.delete($from.pos, $from.end())
  // -1: the new bullet starts where it was inserted, not after itself.
  tr.setSelection(TextSelection.create(tr.doc, tr.mapping.map(insertAt, -1) + 2))
  view.dispatch(tr.scrollIntoView())
  return true
}

function foldListItemAtCaret(view, fold) {
  const item = listItemAtCaret(view.state)
  if (!item || !isFoldableListItem(item.node)) return false
  const folded = outlineFoldPositions(view.state).includes(item.pos)
  if (folded !== fold) toggleOutlineFold(view, item.pos)
  return true
}

document.addEventListener('keydown', (event) => {
  if (event.isComposing || !event.target?.closest?.('.ProseMirror')) return
  // Return and the arrows choose from the `[[` list while it is open.
  if (linkPickerState && linkPicker && !linkPicker.hidden) return
  const view = foldEditorView()
  if (!view || !view.editable) return
  const plain = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey
  let handled = false
  if (event.key === 'Enter' && plain) handled = splitFoldedListItem(view)
  else if (event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey
    && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) {
    handled = foldListItemAtCaret(view, event.key === 'ArrowUp')
  }
  if (!handled) return
  userHasInteracted = true
  event.preventDefault()
  event.stopImmediatePropagation()
}, true)

// ─── Which chevron the pointer is on ────────────────────────────────────────
// A heading's chevron belongs to the heading's line, a bullet's to its own
// first line, reaching left over the gutter the chevron sits in. A pointer on
// a nested bullet's line is on that bullet, not on the one it hangs under.

let hoveredFoldTarget = null
let hoverFrame = null
let lastPointer = null

function sameFoldTarget(a, b) {
  if (!a || !b) return a === b
  return a.kind === b.kind && a.key === b.key && a.pos === b.pos
}

function foldTargetAt(x, y) {
  const reach = 32
  for (const { element, key } of sectionHeadings()) {
    const rect = element.getBoundingClientRect()
    if (y >= rect.top && y <= rect.bottom && x >= rect.left - reach && x <= rect.right) {
      return { kind: 'section', key }
    }
  }
  const view = foldEditorView()
  if (!view) return null
  let best = null
  view.state.doc.descendants((node, pos) => {
    if (node.isTextblock) return false
    if (node.type.name !== 'list_item') return true
    const block = view.nodeDOM(pos)
    const outer = block?.getBoundingClientRect?.()
    if (!outer || y < outer.top || y > outer.bottom) return false
    if (!isFoldableListItem(node)) return true
    const label = listItemLabel(view, pos)
    const firstLine = block.querySelector(':scope > li > .children > .content-dom > :first-child')
    if (!label || !firstLine) return true
    const labelRect = label.getBoundingClientRect()
    const lineRect = firstLine.getBoundingClientRect()
    const top = Math.min(labelRect.top, lineRect.top)
    const bottom = Math.max(labelRect.bottom, lineRect.bottom)
    if (y >= top && y <= bottom && x >= labelRect.left - reach && x <= lineRect.right) {
      if (!best || labelRect.left > best.left) best = { kind: 'item', pos, left: labelRect.left }
    }
    return true
  })
  return best && { kind: best.kind, pos: best.pos }
}

function refreshHoveredFoldTarget() {
  hoverFrame = null
  const target = lastPointer ? foldTargetAt(lastPointer.x, lastPointer.y) : null
  if (sameFoldTarget(target, hoveredFoldTarget)) return
  hoveredFoldTarget = target
  renderFoldControls()
}

document.addEventListener('pointermove', (event) => {
  // On a chevron the pointer is where the chevron already is.
  if (event.target?.closest?.('.artifact-heading-fold')) return
  lastPointer = { x: event.clientX, y: event.clientY }
  if (hoverFrame == null) hoverFrame = requestAnimationFrame(refreshHoveredFoldTarget)
}, { passive: true })

document.documentElement.addEventListener('pointerleave', () => {
  lastPointer = null
  if (hoverFrame == null) hoverFrame = requestAnimationFrame(refreshHoveredFoldTarget)
})

// ─── Keeping the folds ──────────────────────────────────────────────────────
// The host names the doc and hands back what was folded in it when the doc
// opens (`setMarkdown(markdown, { key, folds })`), and hears `foldsChanged`
// whenever that set changes. A fold is kept by what it folds, not by where:
// a section by its heading's text and which of the same-named headings it is,
// a bullet by its line and the lines of the bullets it hangs under. A host
// that never names a doc keeps nothing, and every doc opens unfolded.

let foldDocumentKey = null
let lastFoldsJSON = null
let foldPostFrame = null

function listItemFoldKeys(doc) {
  const keys = []
  const occurrences = new Map()
  const walk = (parent, offset, path) => {
    parent.forEach((child, childOffset) => {
      const pos = offset + childOffset
      if (child.type.name === 'list_item') {
        const itemPath = [...path, child.firstChild?.textContent.trim() ?? '']
        const id = itemPath.join('\u0000')
        const n = occurrences.get(id) ?? 0
        occurrences.set(id, n + 1)
        keys.push({ pos, path: itemPath, n, id: `${id}\u0001${n}` })
        walk(child, pos + 1, itemPath)
      } else if (!child.isTextblock && !child.isLeaf) {
        walk(child, pos + 1, path)
      }
    })
  }
  walk(doc, 0, [])
  return keys
}

function currentFolds() {
  const sections = [...collapsedSectionKeys].map((key) => {
    const separator = key.lastIndexOf('\u0000')
    return { title: key.slice(0, separator), n: Number(key.slice(separator + 1)) }
  })
  const view = foldEditorView()
  const folded = new Set(view ? outlineFoldPositions(view.state) : [])
  const items = folded.size > 0
    ? listItemFoldKeys(view.state.doc).filter(({ pos }) => folded.has(pos)).map(({ path, n }) => ({ path, n }))
    : []
  return { sections, items }
}

function foldsJSON(folds) {
  return folds.sections.length === 0 && folds.items.length === 0 ? '' : JSON.stringify(folds)
}

function postFoldsIfChanged() {
  if (foldDocumentKey == null) return
  const json = foldsJSON(currentFolds())
  if (json === lastFoldsJSON) return
  lastFoldsJSON = json
  post('foldsChanged', { key: foldDocumentKey, folds: json })
}

function scheduleFoldPost() {
  if (foldPostFrame != null) return
  const send = () => {
    foldPostFrame = null
    postFoldsIfChanged()
  }
  // A hidden document gets no frames, and a fold must still reach the host.
  foldPostFrame = document.hidden ? setTimeout(send, 0) : requestAnimationFrame(send)
}

/// Fold what the host kept for this doc, against the doc as it now reads. A
/// heading or bullet whose text changed on another Mac is simply open.
function applyFolds(key, json) {
  foldDocumentKey = key
  let folds = { sections: [], items: [] }
  try {
    if (json) folds = { sections: [], items: [], ...JSON.parse(json) }
  } catch {}
  collapsedSectionKeys = new Set(folds.sections.map(({ title, n }) => `${title}\u0000${n}`))
  const view = foldEditorView()
  if (view) {
    const wanted = new Set(folds.items.map(({ path, n }) => `${path.join('\u0000')}\u0001${n}`))
    const positions = listItemFoldKeys(view.state.doc).filter(({ id }) => wanted.has(id)).map(({ pos }) => pos)
    view.dispatch(view.state.tr.setMeta(outlineFoldKey, { set: positions }).setMeta('addToHistory', false))
  }
  // What the host holds; a fold that no longer finds its line is dropped and
  // the host told.
  lastFoldsJSON = json || ''
  refreshSectionFolds()
}

/// Crepe previews a hovered link by offering its address: copy it, open it,
/// edit it. One of this editor's own source addresses has none to offer — the
/// `foreverlm.invalid` host above is a private stand-in, so the preview read
/// out a dead URL and its copy button put that URL on the clipboard. A grounded
/// passage is prose the writer is reading, not a destination, so the preview
/// only ever had a wrong answer to give. Ordinary links keep theirs.
///
/// Milkdown builds this tooltip's ProseMirror plugin from a spec held in the
/// context, and reads that spec once every `config` callback has run — Crepe
/// registers its own in the constructor, so this one, registered after, sees
/// the finished spec. Wrapping the view leaves Crepe's hover detection,
/// positioning, and teardown exactly as they were.
///
/// A link to another doc or a Notebook is the other private address, and it has
/// exactly one thing to offer: following it. Crepe's preview would read out the
/// stand-in URL and copy it, so it is hidden for these too, and a small tooltip
/// of this editor's own takes its place with an Open button. The host opens
/// the target — the doc in Docs, the Notebook in Notebooks.
function withPrivateAddressPreviews(ctx) {
  const spec = ctx.get(linkPreviewTooltip.key)
  const createView = spec?.view
  if (typeof createView !== 'function') return

  ctx.set(linkPreviewTooltip.key, {
    ...spec,
    view: (view) => {
      const tooltip = createView(view)
      const show = tooltip.show
      const hide = tooltip.hide
      tooltip.show = (mark, from, to, rect, ...rest) => {
        const href = mark?.attrs?.href ?? ''
        const link = inAppLink(href)
        if (link) {
          hide.call(tooltip)
          showInAppLinkTooltip(link, rect)
          return
        }
        const file = fileAttachmentLink(href, view.state.doc.textBetween(from, to))
        if (file) {
          hide.call(tooltip)
          showFileLinkTooltip(file, rect)
          return
        }
        hideInAppLinkTooltip()
        if (isSourceAddress(href)) {
          hide.call(tooltip)
          return
        }
        show.call(tooltip, mark, from, to, rect, ...rest)
      }
      tooltip.hide = (...rest) => {
        hideInAppLinkTooltip()
        hide.call(tooltip, ...rest)
      }
      return tooltip
    },
  })
}

/// A picture keeps its description.
///
/// Crepe's image block — every picture that stands alone on its line — keeps
/// its display size where Markdown keeps a picture's description: it read
/// `![Slide 6](…)` as a size, found no number, and wrote `![1.00](…)` back on
/// the doc's first save (2026-09-29: all 25 slides of the Finbow walkthrough
/// Doc). The description is what a model reading the doc, an export and a
/// published page have of the picture, so it gets an attribute of its own and
/// is written back. `1.00`, `0.62` — the shape Crepe writes — is still read as
/// a size, and a picture without a description still writes its size; one
/// with a description is drawn at its natural size when the doc reopens.
const imageSizeAlt = /^\d+\.\d\d$/

function withPictureDescriptions(ctx) {
  ctx.update(imageBlockSchema.key, (base) => (schemaCtx) => {
    const schema = base(schemaCtx)
    return {
      ...schema,
      attrs: { ...schema.attrs, alt: { default: '', validate: 'string' } },
      parseDOM: (schema.parseDOM ?? []).map((rule) => ({
        ...rule,
        getAttrs: (dom) => ({ ...rule.getAttrs(dom), alt: dom.getAttribute('alt') || '' }),
      })),
      parseMarkdown: {
        match: schema.parseMarkdown.match,
        runner: (state, node, type) => {
          const alt = String(node.alt ?? '').trim()
          const size = imageSizeAlt.test(alt) ? Number(alt) : 0
          state.addNode(type, {
            src: node.url ?? '',
            caption: node.title ?? '',
            ratio: size > 0 ? size : 1,
            alt: size > 0 ? '' : alt,
          })
        },
      },
      toMarkdown: {
        match: schema.toMarkdown.match,
        runner: (state, node) => {
          state.openNode('paragraph')
          state.addNode('image', undefined, undefined, {
            title: node.attrs.caption,
            url: node.attrs.src,
            alt: node.attrs.alt || Number.parseFloat(node.attrs.ratio).toFixed(2),
          })
          state.closeNode()
        },
      },
    }
  })
}

function ensureInAppLinkTooltip() {
  if (inAppLinkTooltip) return inAppLinkTooltip
  inAppLinkTooltip = document.createElement('div')
  inAppLinkTooltip.className = 'artifact-inapp-link-tooltip'
  inAppLinkTooltip.hidden = true
  const open = document.createElement('button')
  open.type = 'button'
  open.dataset.role = 'open'
  open.addEventListener('pointerdown', (event) => event.preventDefault())
  open.addEventListener('click', () => {
    const href = inAppLinkTooltip.dataset.href
    const title = inAppLinkTooltip.dataset.title
    const token = inAppLinkTooltip.dataset.token
    const name = inAppLinkTooltip.dataset.name ?? ''
    hideInAppLinkTooltip(true)
    if (token) post('openAttachmentRequested', { token, name })
    else if (title) post('openTitleRequested', { title })
    else if (href) post('openLinkRequested', { href })
  })
  inAppLinkTooltip.append(open)
  inAppLinkTooltip.addEventListener('mouseenter', () => { inAppLinkTooltipHovered = true })
  inAppLinkTooltip.addEventListener('mouseleave', () => {
    inAppLinkTooltipHovered = false
    hideInAppLinkTooltip()
  })
  document.body.append(inAppLinkTooltip)
  return inAppLinkTooltip
}

/// A link to one of the page's own attached files, `[name.pdf](foreverlm://
/// attachment/<token>)`: `{ token, name }`, or null for any other address. A
/// picture is an image node, never a link, so every attachment link is a file.
function fileAttachmentLink(href, name = '') {
  const value = String(href ?? '')
  if (!value.startsWith(attachmentEditorPrefix) && !value.startsWith(attachmentMarkdownPrefix)) return null
  const encoded = value.slice(value.startsWith(attachmentEditorPrefix) ? attachmentEditorPrefix.length : attachmentMarkdownPrefix.length)
  if (!encoded) return null
  try {
    return { token: decodeURIComponent(encoded), name }
  } catch {
    return null
  }
}

/// A file named in the page offers the one thing a file is for: Save file,
/// which the host answers by writing a copy where the writer chooses.
function showFileLinkTooltip(file, rect) {
  const tooltip = ensureInAppLinkTooltip()
  delete tooltip.dataset.href
  delete tooltip.dataset.title
  tooltip.dataset.kind = 'file'
  tooltip.dataset.token = file.token
  tooltip.dataset.name = file.name || file.token
  tooltip.querySelector('[data-role="open"]').textContent = 'Save file…'
  placeInAppLinkTooltip(tooltip, rect)
}

function showInAppLinkTooltip(link, rect) {
  const tooltip = ensureInAppLinkTooltip()
  tooltip.dataset.href = link.href
  tooltip.dataset.kind = link.kind
  delete tooltip.dataset.title
  delete tooltip.dataset.token
  delete tooltip.dataset.name
  tooltip.querySelector('[data-role="open"]').textContent = inAppLinkKinds.get(link.kind)?.open ?? 'Open'
  placeInAppLinkTooltip(tooltip, rect)
}

/// A page named by its title (`[[Title]]`, `#tag`) offers the same one
/// thing: Open page, which the host answers by opening the page with that
/// title, made when there is none.
function showPageLinkTooltip(title, rect) {
  const tooltip = ensureInAppLinkTooltip()
  delete tooltip.dataset.token
  delete tooltip.dataset.name
  delete tooltip.dataset.href
  tooltip.dataset.kind = 'page'
  tooltip.dataset.title = title
  tooltip.querySelector('[data-role="open"]').textContent = 'Open page'
  placeInAppLinkTooltip(tooltip, rect)
}

function placeInAppLinkTooltip(tooltip, rect) {
  tooltip.hidden = false
  const width = tooltip.offsetWidth
  const left = Math.max(8, Math.min((rect?.left ?? 0), window.innerWidth - width - 8))
  tooltip.style.left = `${left}px`
  tooltip.style.top = `${(rect?.bottom ?? 0) + 6}px`
}

/// Crepe's own hide runs on every pointer move off the link, which is also the
/// move that carries the pointer onto this tooltip — so a hide while the
/// tooltip is hovered is ignored, the way Crepe ignores its own.
function hideInAppLinkTooltip(force = false) {
  if (!inAppLinkTooltip || inAppLinkTooltip.hidden) return
  if (inAppLinkTooltipHovered && !force) return
  inAppLinkTooltip.hidden = true
  inAppLinkTooltipHovered = false
}

// ─── Writing a link to a doc or a Notebook ──────────────────────────────────
// Dragging a doc from the Docs list is one way to write
// `[Title](foreverlm://doc/<id>)`; this is the way from the keyboard, and the
// only way where nothing can be dragged (Web Studio). The host hands the editor
// what a link can point at — `setLinkTargets`: the docs of the same library and
// the Notebooks, each with its current title — and the editor offers them in a
// short caret-anchored list in two places. Typing `[[` in the prose, the wiki
// gesture, opens it over what follows the brackets; and the Link field that ⌘K
// and the header's Link button open takes a title as readily as an address, so
// one field writes both kinds of link. Choosing writes the title as the link's
// text — over a selection, the selected words stay the text — with the stored
// address, so the Markdown is exactly what the drag and the doc tools write.
// The list is a presentation of the host's answer: nothing about it is stored.

// The same list serves the other two caret gestures: `((` searches the
// library's blocks through the host (see "The notes graph" below), and `/`
// offers what can be put on the page (see "The slash menu"). One list, one
// set of keys: ↑↓ move, Return or Tab writes, Escape leaves the typing.

let linkTargets = []
/// The normalized titles of the docs a link can point at: a `[[Title]]` with
/// one of these names a page that exists.
let linkTargetTitleKeys = new Set()
let linkPicker = null
/// `{ source: 'wiki' | 'field' | 'block' | 'slash', query, rows, index,
/// anchorRect, from, to, input }`. A row is `{ key, kind, title, detail }`
/// with what it writes: a link target, a day, a new page, a block, a command.
let linkPickerState = null
/// Where a caret list was dismissed with Escape, `{ source, from }`, so it
/// stays away until its trigger is gone and typed again.
let dismissedTrigger = null
const wikiLinkTrigger = /\[\[([^[\]\n]*)$/
/// `((query`, or `{{embed: ((query` for an embed.
const blockTrigger = /(\{\{\s*(?:\[\[)?embed(?:\]\])?\s*:\s*)?\(\(([^()\n]{0,80})$/
/// `/query` at the start of a line or after a space: a slash inside a word
/// ("and/or", an address) is writing, not a command.
const slashTrigger = /(^|\s)\/([A-Za-z0-9][A-Za-z0-9 ]{0,23})?$/
/// `@query` at the start of a line or after a space: a mention of a page, a
/// notebook, an Idea or a chat. An address ("name@host") is writing, not a
/// mention, and a space straight after the `@` ends it.
const mentionTrigger = /(^|\s)@([^\s@][^@\n]{0,40})?$/

function setLinkTargets(targets) {
  const next = []
  const seen = new Set()
  for (const target of Array.isArray(targets) ? targets : []) {
    const kind = String(target?.kind ?? '').trim().toLowerCase()
    const id = String(target?.id ?? '').trim()
    const title = String(target?.title ?? '').trim()
    if (!inAppLinkKinds.has(kind) || !id || !title) continue
    const href = `${markdownSchemePrefix}${kind}/${encodeURIComponent(id)}`
    if (seen.has(href)) continue
    seen.add(href)
    next.push({ kind, id, title, detail: String(target?.detail ?? '').trim(), href })
  }
  linkTargets = next
  linkTargetTitleKeys = new Set(next.filter((target) => target.kind === 'doc').map((target) => normalizedTitle(target.title)))
  if (linkPickerState && linkPickerState.source !== 'block') refreshLinkPicker(linkPickerState.query)
  // Which titles name a page decides how a title link is drawn.
  if (graph.active) graphContextChanged()
}

function searchKey(value) {
  return String(value ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
}

/// The targets whose title (or detail) contains every typed term, at most
/// eight, the ones whose title begins with the first term ahead of the rest.
/// An empty query lists the first targets in the host's order.
function linkTargetMatches(query, limit = 8) {
  const terms = searchKey(query).split(/\s+/).filter(Boolean)
  const leading = []
  const rest = []
  for (const target of linkTargets) {
    const title = searchKey(target.title)
    const key = `${title} ${searchKey(target.detail)}`
    if (!terms.every((term) => key.includes(term))) continue
    if (terms.length === 0 || title.startsWith(terms[0])) leading.push(target)
    else rest.push(target)
    if (leading.length >= limit) break
  }
  return [...leading, ...rest].slice(0, limit)
}

function ensureLinkPicker() {
  if (linkPicker) return linkPicker
  linkPicker = document.createElement('div')
  linkPicker.className = 'artifact-link-picker'
  linkPicker.hidden = true
  linkPicker.setAttribute('role', 'listbox')
  // The press must not take focus from where the writer is typing.
  linkPicker.addEventListener('pointerdown', (event) => event.preventDefault())
  linkPicker.addEventListener('pointermove', (event) => {
    const row = event.target instanceof Element ? event.target.closest('[data-index]') : null
    if (!row || !linkPickerState) return
    const index = Number(row.dataset.index)
    if (index !== linkPickerState.index) {
      linkPickerState.index = index
      renderLinkPicker()
    }
  })
  linkPicker.addEventListener('click', (event) => {
    const row = event.target instanceof Element ? event.target.closest('[data-index]') : null
    if (row) choosePickerRow(Number(row.dataset.index))
  })
  document.body.append(linkPicker)
  return linkPicker
}

/// What the `((` list says while it has no rows to show.
function blockPickerStatus(state) {
  if (state?.source !== 'block' || state.rows.length > 0) return ''
  if (state.notice) return state.notice
  return state.loading ? 'Searching blocks…' : 'No blocks match'
}

function renderLinkPicker() {
  const picker = ensureLinkPicker()
  const state = linkPickerState
  const status = blockPickerStatus(state)
  if (!state || (state.rows.length === 0 && !status)) {
    picker.hidden = true
    picker.replaceChildren()
    return
  }
  picker.dataset.source = state.source
  const rows = []
  let group = null
  state.rows.forEach((entry, index) => {
    // The slash list is laid out in groups, each under its own heading.
    if (entry.group && entry.group !== group) {
      group = entry.group
      const heading = document.createElement('div')
      heading.className = 'artifact-link-picker-group'
      heading.setAttribute('role', 'presentation')
      heading.textContent = group
      rows.push(heading)
    }
    const row = document.createElement('div')
    row.className = 'artifact-link-picker-row'
    row.dataset.index = String(index)
    row.dataset.kind = entry.kind === 'target' ? entry.target.kind : entry.kind
    row.setAttribute('role', 'option')
    row.setAttribute('aria-selected', index === state.index ? 'true' : 'false')
    if (entry.icon) {
      const icon = document.createElement('span')
      icon.className = 'artifact-link-picker-icon'
      icon.append(slashIcon(entry.icon))
      row.append(icon)
    }
    const title = document.createElement('span')
    title.className = 'artifact-link-picker-title'
    title.textContent = entry.kind === 'newPage' ? `New page “${entry.title}”` : entry.title
    row.append(title)
    if (entry.detail) {
      const element = document.createElement('span')
      element.className = 'artifact-link-picker-detail'
      element.textContent = entry.detail
      row.append(element)
    }
    if (entry.hint) {
      const hint = document.createElement('span')
      hint.className = 'artifact-link-picker-hint'
      hint.textContent = entry.hint
      row.append(hint)
    }
    rows.push(row)
  })
  if (status) {
    const line = document.createElement('div')
    line.className = 'artifact-link-picker-status'
    line.textContent = status
    rows.push(line)
  }
  picker.replaceChildren(...rows)
  picker.hidden = false
  positionLinkPicker()
  keepPickerSelectionInView()
}

/// A list taller than its window scrolls: the row the arrow keys moved to is
/// brought into view, the first row with its heading above it.
function keepPickerSelectionInView() {
  const picker = linkPicker
  if (!picker || picker.hidden || !linkPickerState) return
  const selected = picker.querySelector('.artifact-link-picker-row[aria-selected="true"]')
  if (!selected) return
  if (linkPickerState.index === 0) {
    picker.scrollTop = 0
    return
  }
  const top = selected.offsetTop
  const bottom = top + selected.offsetHeight
  if (top < picker.scrollTop) picker.scrollTop = top - 4
  else if (bottom > picker.scrollTop + picker.clientHeight) picker.scrollTop = bottom - picker.clientHeight + 4
}

/// Under the anchor — the `[[` or the Link field — and never off the page;
/// above it when there is no room below.
function positionLinkPicker() {
  const picker = linkPicker
  const state = linkPickerState
  if (!picker || picker.hidden || !state) return
  const rect = state.anchorRect()
  if (!rect) {
    hideLinkPicker()
    return
  }
  const margin = 8
  // A long list (the slash menu) takes the room the window leaves under the
  // caret, or over it, and scrolls inside that.
  if (state.source === 'slash') {
    const room = Math.max(window.innerHeight - rect.bottom - margin - 6, rect.top - margin - 6)
    picker.style.maxHeight = `${Math.round(Math.max(150, Math.min(360, room)))}px`
  } else {
    picker.style.maxHeight = ''
  }
  const width = picker.offsetWidth
  const height = picker.offsetHeight
  const left = Math.max(margin, Math.min(rect.left, window.innerWidth - width - margin))
  let top = rect.bottom + 6
  if (top + height > window.innerHeight - margin && rect.top - height - 6 >= margin) top = rect.top - height - 6
  picker.style.left = `${Math.round(left)}px`
  picker.style.top = `${Math.round(top)}px`
}

function targetRow(target) {
  const detail = target.detail
    || (target.kind === 'notebook' ? 'Notebook' : target.kind === 'idea' ? 'Idea' : target.kind === 'chat' ? 'Chat' : '')
  return { key: target.href, kind: 'target', title: target.title, detail, target }
}

/// Whether a title names a page this library has: one of the docs a link can
/// point at, or a title the host's graph knows.
function titleNamesPage(title) {
  const key = normalizedTitle(title)
  return linkTargetTitleKeys.has(key) || graph.titles.has(key)
}

/// The `[[` list: the docs and Notebooks as before, then the Ideas, then the
/// days the query names, then New page when no page has that title. Days
/// and new pages need a host that keeps the graph; without one the list is
/// what it always was.
function wikiRows(query) {
  const matches = linkTargetMatches(query, 64)
  const rows = [
    ...matches.filter((target) => target.kind !== 'idea').slice(0, 8).map(targetRow),
    ...matches.filter((target) => target.kind === 'idea').slice(0, 4).map(targetRow),
  ]
  if (!graph.active) return rows
  const wanted = String(query ?? '').trim()
  const days = graph.allowsDates ? daysForQuery(wanted) : []
  for (const day of days) {
    rows.push({ key: `day:${day.dayKey}`, kind: 'day', title: dayTitle(day.dayKey), detail: day.label, dayKey: day.dayKey })
  }
  const namesDay = days.length > 0 || Boolean(dayKeyFromTitle(wanted))
  if (wanted && !namesDay && !titleNamesPage(wanted)) {
    rows.push({ key: `new:${wanted}`, kind: 'newPage', title: wanted, detail: '' })
  }
  return rows
}

// ─── The slash menu ─────────────────────────────────────────────────────────
// Typing `/` at the start of a line or after a space offers what can be put
// on the page, as ChatGPT's Pages does: write with the AI, make a page inside
// this one, add a picture, change the block into a heading, a list, a quote,
// a table. The list is the caret list the `[[` gesture uses, drawn with group
// headings, an icon and a line saying what the row does; typing narrows it to
// the rows with a word each typed term begins, ↑↓ move, Return or Tab writes,
// Escape leaves the typing.
//
// A row is offered only where it works. The block rows are the editor's own
// and are always there; the rows that need the host — a page made by the
// library, a picture taken from disk or drawn by a model — appear once the
// host says it can do them (`setSlashFeatures`), and the day and block rows
// once the host keeps the notes graph.

const slashGroups = ['Generate', 'Create', 'Media', 'Basic', 'Notes']

/// What the host can do for a row that is not the editor's own, set by
/// `setSlashFeatures({ pages, images, imageGeneration, visualize, files })`.
let slashFeatures = { pages: false, images: false, imageGeneration: false, visualize: false, files: false }

function setSlashFeatures(features) {
  const next = { pages: false, images: false, imageGeneration: false, visualize: false, files: false }
  for (const key of Object.keys(next)) next[key] = Boolean(features?.[key])
  const redraw = next.visualize !== slashFeatures.visualize
  slashFeatures = next
  if (linkPickerState?.source === 'slash') refreshLinkPicker(linkPickerState.query)
  // Whether a visualization block is drawn depends on it.
  if (redraw) activeEditorView()?.dispatch(activeEditorView().state.tr.setMeta('addToHistory', false))
}

/// 16×16 line icons, drawn in the text colour. Inner SVG only: `slashIcon`
/// wraps one.
const slashIcons = {
  sparkle: '<path d="M8 1.8l1.3 3.6 3.6 1.3-3.6 1.3L8 11.6 6.7 8 3.1 6.7l3.6-1.3zM12.6 10.4l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6z"/>',
  page: '<path d="M4 1.8h5.2L12.4 5v9.2H4z"/><path d="M9 1.8V5.2h3.4M6 8.4h4.4M6 10.8h4.4"/>',
  link: '<path d="M6.8 9.2a2.6 2.6 0 0 0 3.7 0l2-2a2.6 2.6 0 0 0-3.7-3.7l-.7.7"/><path d="M9.2 6.8a2.6 2.6 0 0 0-3.7 0l-2 2a2.6 2.6 0 0 0 3.7 3.7l.7-.7"/>',
  image: '<rect x="2" y="2.8" width="12" height="10.4" rx="1.8"/><circle cx="6" cy="6.6" r="1.1"/><path d="M2.4 11.4l3.4-3 2.6 2.2 2.2-1.8 3.2 2.8"/>',
  paperclip: '<path d="M12.6 7.6l-4.7 4.7a3 3 0 0 1-4.2-4.2l5-5a2 2 0 0 1 2.8 2.8l-5 5a1 1 0 0 1-1.4-1.4l4.4-4.4"/>',
  chart: '<path d="M2.4 2.4v11.2h11.2"/><path d="M5.4 10.6l2.6-3.4 2.2 1.8 3-4.2"/>',
  clipboard: '<rect x="3.4" y="2.8" width="9.2" height="11" rx="1.6"/><path d="M6 2.8V2h4v.8M5.8 7h4.4M5.8 9.6h4.4M5.8 12h2.4"/>',
  chat: '<path d="M3 3.4h10v7H8.2L5 13V10.4H3z"/><path d="M5.8 6.2h4.4M5.8 8.2h2.6"/>',
  search: '<circle cx="7" cy="7" r="4.2"/><path d="M10.1 10.1L14 14"/>',
  palette: '<path d="M8 2a6 6 0 1 0 0 12c.9 0 1.3-.7 1-1.4-.4-.8.1-1.6 1-1.6h1.4A2.6 2.6 0 0 0 14 8.4C14 4.9 11.4 2 8 2z"/><circle cx="5.2" cy="7.2" r=".8"/><circle cx="8" cy="5" r=".8"/><circle cx="10.8" cy="6.8" r=".8"/>',
  text: '<path d="M3 4.2h10M8 4.2v8.6M5.6 12.8h4.8"/>',
  h1: '<path d="M2.6 3.6v8.8M8 3.6v8.8M2.6 8h5.4M11 6.2l1.8-1v7.8"/>',
  h2: '<path d="M2.2 3.6v8.8M7.4 3.6v8.8M2.2 8h5.2M10.2 6a1.7 1.7 0 1 1 2.6 1.4l-2.6 2.2v1.2h3.4"/>',
  h3: '<path d="M2.2 3.6v8.8M7.4 3.6v8.8M2.2 8h5.2M10.4 5.6h2.8L11.8 8a1.8 1.8 0 1 1-1.4 3"/>',
  bullet: '<circle cx="3.4" cy="4.6" r=".9"/><circle cx="3.4" cy="8" r=".9"/><circle cx="3.4" cy="11.4" r=".9"/><path d="M6.4 4.6h7M6.4 8h7M6.4 11.4h7"/>',
  numbered: '<path d="M2.6 3.4l1-.6v3M2.4 8.2c.4-.5 1.9-.4 1.9.5 0 .7-1.7 1.2-1.9 2h2.1M2.4 12.6h1.5l-.8 1.2a.9.9 0 1 1-.7.3M6.6 4.6h7M6.6 8.4h7M6.6 12.2h7"/>',
  todo: '<rect x="2.2" y="2.6" width="4.4" height="4.4" rx="1"/><path d="M3.2 4.8l1 1 1.4-1.8M8.6 4.8h5.2M2.2 10.2h4.4v3.4H2.2zM8.6 11.9h5.2"/>',
  quote: '<path d="M3 4v8M6.4 5h7M6.4 8h7M6.4 11h4.4"/>',
  code: '<path d="M5.6 4.6L2.2 8l3.4 3.4M10.4 4.6L13.8 8l-3.4 3.4M9 3.4L7 12.6"/>',
  divider: '<path d="M2.4 8h11.2"/><path d="M5 4.6h6M5 11.4h6" opacity=".45"/>',
  table: '<rect x="2" y="2.8" width="12" height="10.4" rx="1.6"/><path d="M2 6.6h12M2 10h12M6 2.8v10.4"/>',
  sigma: '<path d="M12.4 3.6H4.2L8.4 8l-4.2 4.4h8.2"/>',
  footnote: '<path d="M2.4 6.4h6.8M2.4 9.6h4.6M2.4 13h11.2" opacity=".55"/><path d="M10.6 3.4l1.2-.8V7M10.4 7h2.6"/>',
  calendar: '<rect x="2.2" y="3" width="11.6" height="10.6" rx="1.8"/><path d="M2.2 6.6h11.6M5.4 1.8v2.4M10.6 1.8v2.4"/>',
  reference: '<path d="M5.4 3H4.2v10h1.2M10.6 3h1.2v10h-1.2M7 6.4h2M7 9.6h2"/>',
  embed: '<rect x="2.2" y="3" width="11.6" height="10" rx="1.8"/><path d="M5.2 6.6l-1.2 1.4 1.2 1.4M10.8 6.6L12 8l-1.2 1.4M8.6 5.6L7.4 10.6"/>',
  // The selection bar's marks and its type menu.
  mention: '<circle cx="8" cy="8" r="2.4"/><path d="M10.4 8v1.1a1.6 1.6 0 0 0 3.2 0V8A5.6 5.6 0 1 0 8 13.6c1.1 0 2.1-.3 3-.9"/>',
  highlight: '<path d="M9.6 2.6l3.8 3.8-5.7 5.7-3.2.6.6-3.2z"/><path d="M2.4 13.6h4.4"/>',
  grip: '<circle cx="6" cy="3.6" r=".9" fill="currentColor"/><circle cx="10" cy="3.6" r=".9" fill="currentColor"/><circle cx="6" cy="8" r=".9" fill="currentColor"/><circle cx="10" cy="8" r=".9" fill="currentColor"/><circle cx="6" cy="12.4" r=".9" fill="currentColor"/><circle cx="10" cy="12.4" r=".9" fill="currentColor"/>',
  plus: '<path d="M8 3v10M3 8h10"/>',
  width: '<path d="M2.4 8h11.2M5 5.4L2.4 8 5 10.6M11 5.4L13.6 8 11 10.6"/>',
  columns: '<rect x="2" y="3" width="12" height="10" rx="1.6"/><path d="M6 3v10M10 3v10"/>',
  rowBelow: '<rect x="2" y="2.8" width="12" height="6.4" rx="1.4"/><path d="M2 6h12M8 11.2v3.2M6.4 12.8h3.2"/>',
  copy: '<rect x="5.4" y="5.4" width="8" height="8" rx="1.6"/><path d="M10.6 5.4V4a1.4 1.4 0 0 0-1.4-1.4H4A1.4 1.4 0 0 0 2.6 4v5.2A1.4 1.4 0 0 0 4 10.6h1.4"/>',
  markdown: '<rect x="1.8" y="3.4" width="12.4" height="9.2" rx="1.8"/><path d="M4.2 10V6l1.8 2.2L7.8 6v4M11 6v4M9.6 8.6L11 10l1.4-1.4"/>',
  trash: '<path d="M3 4.4h10M6.4 4.4V3h3.2v1.4M4.4 4.4l.6 8.4h6l.6-8.4M6.8 7v3.8M9.2 7v3.8"/>',
  bold: '<path d="M4.8 2.9h3.9a2.45 2.45 0 0 1 0 4.9H4.8zM4.8 7.8h4.5a2.65 2.65 0 0 1 0 5.3H4.8z" stroke-width="1.8"/>',
  italic: '<path d="M7.2 2.9h4.6M4.2 13.1h4.6M9.5 2.9L6.5 13.1" stroke-width="1.5"/>',
  strikethrough: '<path d="M11.1 4.8C10.6 3.6 9.4 2.9 8 2.9c-1.9 0-3.2 1-3.2 2.4 0 .8.4 1.4 1.2 1.9M2.6 8.4h10.8M10.4 10.2c.5.4.8 1 .8 1.6 0 1.5-1.4 2.4-3.3 2.4-1.6 0-2.9-.7-3.4-1.9" stroke-width="1.4"/>',
  chevronDown: '<path d="M4 6l4 4 4-4" stroke-width="1.6"/>',
  check: '<path d="M3.4 8.4l3 3 6.2-6.6" stroke-width="1.6"/>',
}

function slashIcon(name, size = 16) {
  const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  icon.setAttribute('viewBox', '0 0 16 16')
  icon.setAttribute('width', String(size))
  icon.setAttribute('height', String(size))
  icon.setAttribute('fill', 'none')
  icon.setAttribute('stroke', 'currentColor')
  icon.setAttribute('stroke-width', '1.3')
  icon.setAttribute('stroke-linecap', 'round')
  icon.setAttribute('stroke-linejoin', 'round')
  icon.setAttribute('aria-hidden', 'true')
  icon.innerHTML = slashIcons[name] ?? ''
  return icon
}

/// The block rows run Milkdown's own block commands on the block the caret is
/// in, after the `/query` is taken out of it: the ones Crepe's slash menu ran
/// before this editor turned that menu off.
const slashBlockCommands = {
  text: (ctx, commands) => commands.call(setBlockTypeCommand.key, { nodeType: paragraphSchema.type(ctx) }),
  h1: (ctx, commands) => commands.call(setBlockTypeCommand.key, { nodeType: headingSchema.type(ctx), attrs: { level: 1 } }),
  h2: (ctx, commands) => commands.call(setBlockTypeCommand.key, { nodeType: headingSchema.type(ctx), attrs: { level: 2 } }),
  h3: (ctx, commands) => commands.call(setBlockTypeCommand.key, { nodeType: headingSchema.type(ctx), attrs: { level: 3 } }),
  bullet: (ctx, commands) => commands.call(wrapInBlockTypeCommand.key, { nodeType: bulletListSchema.type(ctx) }),
  numbered: (ctx, commands) => commands.call(wrapInBlockTypeCommand.key, { nodeType: orderedListSchema.type(ctx) }),
  todo: (ctx, commands) => commands.call(wrapInBlockTypeCommand.key, { nodeType: listItemSchema.type(ctx), attrs: { checked: false } }),
  quote: (ctx, commands) => commands.call(wrapInBlockTypeCommand.key, { nodeType: blockquoteSchema.type(ctx) }),
  code: (ctx, commands) => commands.call(setBlockTypeCommand.key, { nodeType: codeBlockSchema.type(ctx) }),
  math: (ctx, commands) => commands.call(addBlockTypeCommand.key, { nodeType: codeBlockSchema.type(ctx), attrs: { language: 'LaTeX' } }),
  divider: (ctx, commands) => commands.call(addBlockTypeCommand.key, { nodeType: hrSchema.type(ctx) }),
  table: (ctx, commands) => {
    const { from } = ctx.get(editorViewCtx).state.selection
    commands.call(addBlockTypeCommand.key, { nodeType: createTable(ctx, 3, 3) })
    commands.call(selectTextNearPosCommand.key, { pos: from })
  },
}

/// One row per thing the menu can put on the page. `needs` names the host
/// feature a row waits for; `keywords` are the other words that find it.
const slashItems = [
  { id: 'chat', group: 'Generate', title: 'Chat', detail: 'Ask about this page or anything in your library', icon: 'chat', keywords: ['ask', 'question', 'research', 'library', 'sources', 'ai'] },
  { id: 'find-sources', group: 'Generate', title: 'Find sources', detail: 'Search your library and the web from Chat', icon: 'search', keywords: ['find', 'search', 'research', 'references', 'papers', 'podcast', 'library', 'web'] },
  { id: 'generate', group: 'Generate', title: 'Generate', detail: 'Describe what you want to write', icon: 'sparkle', keywords: ['ai', 'write', 'draft', 'compose'] },
  { id: 'visualize', group: 'Generate', title: 'Visualize', detail: 'Create an interactive visualization', icon: 'chart', keywords: ['chart', 'diagram', 'graph', 'interactive', 'calculator', 'plot'], needs: 'visualize' },
  { id: 'page', group: 'Create', title: 'Page', detail: 'Create a page inside this one', icon: 'page', keywords: ['new', 'subpage', 'child'], needs: 'pages' },
  { id: 'link', group: 'Create', title: 'Link to page', detail: 'Link to a page or a Notebook', icon: 'link', keywords: ['reference', 'notebook'] },
  { id: 'mention', group: 'Create', title: 'Mention', detail: 'Link a page, notebook, idea or chat', icon: 'mention', hint: '@', keywords: ['at', 'reference', 'chat', 'notebook', 'page', 'idea'] },
  { id: 'image', group: 'Media', title: 'Image', detail: 'Upload an image', icon: 'image', keywords: ['picture', 'photo', 'upload'], needs: 'images' },
  { id: 'file', group: 'Media', title: 'File', detail: 'Upload a file for download', icon: 'paperclip', keywords: ['attach', 'attachment', 'document', 'pdf', 'download'], needs: 'files' },
  { id: 'draw', group: 'Media', title: 'Generate image', detail: 'Describe a picture and the AI draws it', icon: 'palette', keywords: ['image', 'picture', 'draw', 'ai', 'illustration'], needs: 'imageGeneration' },
  { id: 'instructions', group: 'Basic', title: 'Assistant instructions', detail: 'Guidance for assistants working on this page', icon: 'clipboard', keywords: ['agent', 'ai', 'rules', 'guidance', 'instructions'] },
  { id: 'highlight', group: 'Basic', title: 'Highlight', detail: 'Make a passage stand out', icon: 'highlight', keywords: ['callout', 'note', 'important', 'tip', 'marker'] },
  { id: 'prompt', group: 'Basic', title: 'Prompt', detail: 'A request readers can open in Chat', icon: 'chat', keywords: ['ask', 'question', 'request'] },
  { id: 'text', group: 'Basic', title: 'Text', detail: 'Plain paragraph', icon: 'text', keywords: ['paragraph', 'plain'] },
  { id: 'h1', group: 'Basic', title: 'Heading 1', icon: 'h1', hint: '#', keywords: ['h1', 'title', 'large'] },
  { id: 'h2', group: 'Basic', title: 'Heading 2', icon: 'h2', hint: '##', keywords: ['h2', 'subtitle', 'medium'] },
  { id: 'h3', group: 'Basic', title: 'Heading 3', icon: 'h3', hint: '###', keywords: ['h3', 'small'] },
  { id: 'bullet', group: 'Basic', title: 'Bulleted list', icon: 'bullet', hint: '-', keywords: ['bullet', 'list', 'unordered', 'ul'] },
  { id: 'numbered', group: 'Basic', title: 'Numbered list', icon: 'numbered', hint: '1.', keywords: ['ordered', 'list', 'ol'] },
  { id: 'todo', group: 'Basic', title: 'Checklist', icon: 'todo', hint: '[ ]', keywords: ['todo', 'task', 'checkbox', 'to-do'] },
  { id: 'quote', group: 'Basic', title: 'Quote', icon: 'quote', hint: '>', keywords: ['blockquote', 'cite'] },
  { id: 'code', group: 'Basic', title: 'Code', detail: 'Code block', icon: 'code', hint: '```', keywords: ['snippet', 'pre'] },
  { id: 'divider', group: 'Basic', title: 'Divider', icon: 'divider', hint: '---', keywords: ['line', 'rule', 'separator', 'hr'] },
  { id: 'table', group: 'Basic', title: 'Table', icon: 'table', keywords: ['grid', 'rows', 'columns'] },
  { id: 'math', group: 'Basic', title: 'Equation', detail: 'A block of LaTeX', icon: 'sigma', hint: '$$', keywords: ['math', 'latex', 'formula'] },
  { id: 'footnote', group: 'Basic', title: 'Footnote', detail: 'A numbered note at the foot of the page', icon: 'footnote', hint: '⌥⌘F', keywords: ['note', 'endnote', 'citation', 'reference', 'fn'], needs: 'prose' },
  { id: 'today', group: 'Notes', title: 'Today', icon: 'calendar', offset: 0, needs: 'dates' },
  { id: 'tomorrow', group: 'Notes', title: 'Tomorrow', icon: 'calendar', offset: 1, needs: 'dates' },
  { id: 'yesterday', group: 'Notes', title: 'Yesterday', icon: 'calendar', offset: -1, needs: 'dates' },
  { id: 'reference', group: 'Notes', title: 'Block Reference', detail: '((', icon: 'reference', keywords: ['block', 'transclude'], needs: 'graph' },
  { id: 'embed', group: 'Notes', title: 'Embed Block', detail: '{{embed}}', icon: 'embed', keywords: ['block', 'transclude'], needs: 'graph' },
]

function slashItemAvailable(item) {
  switch (item.needs) {
    case 'pages': return slashFeatures.pages || graph.active
    case 'images': return slashFeatures.images
    case 'imageGeneration': return slashFeatures.imageGeneration
    case 'visualize': return slashFeatures.visualize
    case 'files': return slashFeatures.files
    case 'dates': return graph.active && graph.allowsDates
    case 'graph': return graph.active
    // A note has no footnotes of its own (`insertFootnote`).
    case 'prose': return caretTakesFootnote(activeEditorView())
    default: return true
  }
}

/// The `/` list: every row on offer with a word that each typed term begins,
/// in the order of the groups.
function slashRows(query) {
  const terms = searchKey(query).split(/\s+/).filter(Boolean)
  return slashItems
    .filter(slashItemAvailable)
    .filter((item) => {
      const words = [item.title, ...(item.keywords ?? [])].flatMap((text) => searchKey(text).split(/\s+/))
      return terms.every((term) => words.some((word) => word.startsWith(term)))
    })
    .sort((left, right) => slashGroups.indexOf(left.group) - slashGroups.indexOf(right.group))
    .map((item) => ({
      key: `slash:${item.id}`,
      kind: 'command',
      group: item.group,
      icon: item.icon,
      title: item.title,
      detail: item.offset == null ? (item.detail ?? '') : dayTitle(relativeDayKey(item.offset)),
      hint: item.hint ?? '',
      command: item,
    }))
}

function blockRow(hit, index) {
  const block = hit.block ?? {}
  return {
    key: `block:${hit.docID}:${block.blockID ?? block.key ?? ''}:${index}`,
    kind: 'block',
    title: String(block.plainText || block.markdown || '').trim() || 'Empty block',
    detail: String(hit.docTitle ?? ''),
    hit,
  }
}

function pickerRows(state) {
  switch (state.source) {
    case 'wiki': return wikiRows(state.query)
    case 'slash': return slashRows(state.query)
    case 'mention': return linkTargetMatches(state.query, 10).map(targetRow)
    case 'block': return state.rows ?? []
    case 'field': return linkFieldRows(state)
    default: return linkTargetMatches(state.query).map(targetRow)
  }
}

function openLinkPicker(next) {
  const previous = linkPickerState
  const rows = pickerRows(next)
  const sameList = previous
    && previous.source === next.source
    && previous.rows.length === rows.length
    && previous.rows.every((row, index) => row.key === rows[index].key)
  linkPickerState = {
    ...next,
    rows,
    index: sameList ? Math.min(previous.index, Math.max(rows.length - 1, 0)) : 0,
  }
  renderLinkPicker()
}

function refreshLinkPicker(query) {
  if (linkPickerState) openLinkPicker({ ...linkPickerState, query })
}

function hideLinkPicker() {
  linkPickerState = null
  clearTimeout(blockSearchTimer)
  blockSearchTimer = null
  if (linkPicker) {
    linkPicker.hidden = true
    linkPicker.replaceChildren()
  }
}

/// Escape: the list goes, the typing stays.
function dismissLinkPicker() {
  const state = linkPickerState
  if (state && state.source !== 'field') dismissedTrigger = { source: state.source, from: state.from }
  hideLinkPicker()
}

function moveLinkPickerSelection(step) {
  const state = linkPickerState
  if (!state || state.rows.length === 0) return
  state.index = (state.index + step + state.rows.length) % state.rows.length
  renderLinkPicker()
}

/// Write `target` as a link: over `[from, to)` when the range is empty or is
/// the `[[query` being replaced, the title becomes the text; over a selection
/// the selected words keep standing and take the address (any link they had
/// goes). The address is translated to the editor's private form so
/// Milkdown's link mark keeps it, as `insertLinksAt` does for a drop.
function writeInAppLink(target, from, to, { replaceText = false } = {}) {
  const view = activeEditorView()
  if (!view) return
  const { state } = view
  const { schema } = state
  const linkType = schema.marks.link
  const mark = linkType.create({ href: editorAddress(target.href) })
  const size = state.doc.content.size
  const start = Math.max(0, Math.min(Number(from), size))
  const end = Math.max(start, Math.min(Number(to), size))
  const tr = state.tr
  if (start === end || replaceText) {
    const text = schema.text(target.title, [mark])
    tr.replaceWith(start, end, text)
    tr.setSelection(TextSelection.create(tr.doc, start + text.nodeSize))
  } else {
    tr.removeMark(start, end, linkType)
    tr.addMark(start, end, mark)
    tr.setSelection(TextSelection.create(tr.doc, end))
  }
  // The caret lands at the link's end, where the link mark is inclusive: the
  // next word typed would join the link. What follows a link is prose.
  tr.setStoredMarks([])
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

function choosePickerRow(index) {
  const state = linkPickerState
  const row = state?.rows[index]
  const view = activeEditorView()
  if (!row || !view) return
  if (state.source === 'field') {
    const input = state.input
    if (row.kind === 'web') {
      // A web address is Crepe's own kind of link: the field confirms it,
      // over the selected words or, with none, as the address itself. The
      // field is handed the address with its scheme first, and the Return
      // reaches it once the list is gone (the field's input redraws it).
      if (input.value !== row.address) {
        input.value = row.address
        input.dispatchEvent(new Event('input', { bubbles: true }))
      }
      hideLinkPicker()
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      return
    }
    // Crepe selected the link's range when it opened the field, and its
    // Escape puts the field away and hands focus back to the prose; the
    // link is then written over that range here rather than confirmed
    // through the field, whose confirm would make the address the text.
    const { from, to } = view.state.selection
    hideLinkPicker()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    writeInAppLink(row.target, from, to)
    return
  }
  const { from, to } = state
  if (state.source === 'block') {
    if (writeBlockReference(row.hit, from, to, { embed: state.embed })) {
      hideLinkPicker()
      dismissedTrigger = null
      return
    }
    // The block was edited here since the search read it: the list says so
    // and asks again, rather than writing a reference to the wrong words.
    linkPickerState = { ...state, rows: [], index: 0, loading: true, notice: 'That block changed here. Searching again…' }
    renderLinkPicker()
    scheduleBlockSearch()
    return
  }
  hideLinkPicker()
  dismissedTrigger = null
  if (state.source === 'slash') {
    runSlashCommand(row.command, from, to)
    return
  }
  writeWikiRow(row, from, to, { tag: state.tag })
}

/// What a `[[` row writes. A doc, Notebook or Idea is linked by id, as
/// before; a day is linked to its daily note and a new page to the id made
/// for it here, and the host is asked to make either (`pageCreationRequested`,
/// which it answers by making the page if it is not there yet). After `#`
/// the row is written as a tag, `#[[Title]]`, the page named by its title.
function writeWikiRow(row, from, to, { tag = false } = {}) {
  if (row.kind === 'day') {
    writeDayLink(row.dayKey, from, to, { tag })
    return
  }
  if (row.kind === 'newPage') {
    const docID = newPageID()
    if (tag) writePlainText(`[[${row.title}]]`, from, to)
    else writeInAppLink({ title: row.title, href: `${markdownSchemePrefix}doc/${docID}` }, from, to, { replaceText: true })
    post('pageCreationRequested', { docID, title: row.title })
    return
  }
  if (tag) writePlainText(`[[${row.target.title}]]`, from, to)
  else writeInAppLink(row.target, from, to, { replaceText: true })
}

/// A day's link, `[October 7th, 2026](foreverlm://doc/daily-2026-10-07)`.
function writeDayLink(dayKey, from, to, { tag = false } = {}) {
  const title = dayTitle(dayKey)
  const docID = dailyNoteID(dayKey)
  if (!title) return
  if (tag) writePlainText(`[[${title}]]`, from, to)
  else writeInAppLink({ title, href: `${markdownSchemePrefix}doc/${docID}` }, from, to, { replaceText: true })
  post('pageCreationRequested', { docID, title, dayKey })
}

/// A new page's id: a lowercase UUID, the shape the app gives every Doc.
function newPageID() {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID().toLowerCase()
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

/// Plain words over `[from, to)`, the caret after them.
function writePlainText(text, from, to) {
  const view = activeEditorView()
  if (!view) return
  const tr = view.state.tr.insertText(text, from, to)
  tr.setSelection(TextSelection.create(tr.doc, from + text.length))
  tr.setStoredMarks([])
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

/// Whether a range carries a link that is a destination: a web address or
/// another doc. Grounding is a link mark too, but prose that stands on a
/// source is still prose to type in.
function rangeHasDestinationLink(doc, from, to, linkType) {
  let found = false
  doc.nodesBetween(from, to, (node) => {
    if (found || !node.isText) return !found
    found = node.marks.some((mark) => mark.type === linkType && groundingSourceIDs(mark.attrs?.href ?? '').length === 0)
    return false
  })
  return found
}

/// The caret gesture being typed, or null: `((query` (a block search; the
/// graph's), `[[query` (a link), or `/query` (a slash command). The
/// caret must be a collapsed text selection in prose (not code), the trigger
/// on its line, and the run not already a link. A caret inside a reference
/// or title link that is already complete is editing it, not searching.
function caretTriggerAt(view) {
  const { selection, doc, schema } = view.state
  if (!selection.empty || !(selection instanceof TextSelection)) return null
  const $from = selection.$from
  if (!$from.parent.isTextblock || $from.parent.type.spec.code) return null
  const before = $from.parent.textBetween(0, $from.parentOffset, ' ', ' ')
  const after = $from.parent.textBetween($from.parentOffset, $from.parent.content.size, ' ', ' ')
  const allowed = (from) => !rangeHasDestinationLink(doc, from, $from.pos, schema.marks.link)
    && !(schema.marks.inlineCode && doc.rangeHasMark(from, $from.pos, schema.marks.inlineCode))
  if (graph.active) {
    const match = blockTrigger.exec(before)
    const insideReference = match && /^[a-z0-9]*$/.test(match[2]) && /^[a-z0-9]*\)\)/.test(after)
    if (match && !insideReference) {
      const from = $from.pos - match[0].length
      if (allowed(from)) return { source: 'block', from, to: $from.pos, query: match[2], embed: Boolean(match[1]) }
    }
  }
  const wiki = wikiLinkTrigger.exec(before)
  if (wiki && !/^[^[\]\n]*\]\]/.test(after)) {
    const from = $from.pos - wiki[0].length
    if (allowed(from)) {
      // `#[[` begins a tag: a `#` at the start of the line or after a space.
      const hash = wiki.index - 1
      const tag = graph.active && before[hash] === '#' && (hash === 0 || /[\s(]/.test(before[hash - 1]))
      return { source: 'wiki', from, to: $from.pos, query: wiki[1], tag }
    }
  }
  const slash = slashTrigger.exec(before)
  if (slash) {
    const from = $from.pos - (slash[0].length - slash[1].length)
    if (allowed(from)) return { source: 'slash', from, to: $from.pos, query: slash[2] ?? '' }
  }
  const mention = mentionTrigger.exec(before)
  if (mention) {
    const from = $from.pos - (mention[0].length - mention[1].length)
    if (allowed(from)) return { source: 'mention', from, to: $from.pos, query: mention[2] ?? '' }
  }
  return null
}

function caretAnchor(view, position) {
  return () => {
    try {
      const coords = view.coordsAtPos(position)
      return { left: coords.left, top: coords.top, bottom: coords.bottom }
    } catch {
      return null
    }
  }
}

/// Open, move or put away the caret list after any change to the document or
/// its selection.
function refreshCaretPickers() {
  const view = activeEditorView()
  const current = linkPickerState && linkPickerState.source !== 'field' ? linkPickerState : null
  if (!view || !isEditable || !view.hasFocus()) {
    if (current) hideLinkPicker()
    return
  }
  const trigger = caretTriggerAt(view)
  if (!trigger) {
    dismissedTrigger = null
    if (current) hideLinkPicker()
    return
  }
  if (dismissedTrigger && dismissedTrigger.source === trigger.source && dismissedTrigger.from === trigger.from) {
    if (current) hideLinkPicker()
    return
  }
  if (current && (current.source !== trigger.source || current.from !== trigger.from)) hideLinkPicker()
  if (trigger.source === 'block') {
    openBlockPicker(trigger, view)
    return
  }
  openLinkPicker({ ...trigger, anchorRect: caretAnchor(view, trigger.from) })
}

function linkFieldInput(target) {
  return target instanceof HTMLInputElement && target.matches('.milkdown-link-edit input') ? target : null
}

/// A scheme with `//`, `mailto:` or `tel:`, `www.`, a bare domain with a path,
/// `localhost`, an anchor or a path: the field holds an address. A title with
/// a colon in it ("Biotech: strategy") is a title, not a scheme.
function looksLikeAddress(value) {
  const text = String(value ?? '').trim()
  if (!text) return false
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(text)
    || /^(mailto|tel):\S/i.test(text)
    || /^(www\.|[#/])/i.test(text)
    || /^localhost(:\d+)?(\/\S*)?$/i.test(text)
    || /^\S+\.[a-z]{2,}(:\d+)?(\/\S*)?$/i.test(text)
}

/// What a link to an address the field holds points at. One typed without a
/// scheme ("nature.com/articles/…") gets `https://`: written bare, it was a
/// relative address that opened nothing.
function webAddressFromField(value) {
  const text = String(value ?? '').trim()
  if (!text || /^[a-z][a-z0-9+.-]*:/i.test(text) || /^[#/]/.test(text)) return text
  return `https://${text}`
}

/// Whether any words in a range stand on attached sources.
function rangeHasGrounding(state, from, to) {
  const link = state.schema.marks.link
  let found = false
  state.doc.nodesBetween(from, to, (node) => {
    if (found || !node.isText) return !found
    found = node.marks.some((mark) => mark.type === link && groundingSourceIDs(mark.attrs.href).length > 0)
    return false
  })
  return found
}

/// The Link field's list. An address is offered as itself, the first row,
/// so a web link is as plain a choice as a page (product owner, 2026-10-12:
/// "the link really should allow for a hyperlink"); anything else searches
/// the pages and Notebooks. A passage's attached sources and a web address
/// ride the same link mark, so a web link written over grounded words takes
/// their sources off them, and the row says so before it is chosen.
function linkFieldRows(state) {
  const query = String(state.query ?? '').trim()
  if (!looksLikeAddress(query)) return linkTargetMatches(query).map(targetRow)
  return [{
    key: `web:${query}`,
    kind: 'web',
    icon: 'link',
    title: `Link to ${query}`,
    detail: state.grounded ? 'Replaces the attached sources' : '',
    address: webAddressFromField(query),
  }]
}

function refreshLinkFieldPicker(input) {
  const current = linkPickerState?.source === 'field' ? linkPickerState : null
  if (!input || !isEditable || document.activeElement !== input) {
    if (current) hideLinkPicker()
    return
  }
  const view = activeEditorView()
  const selection = view?.state.selection
  const anchor = input.closest('.milkdown-link-edit') ?? input
  openLinkPicker({
    source: 'field',
    input,
    query: input.value,
    grounded: Boolean(view && selection && selection.to > selection.from && rangeHasGrounding(view.state, selection.from, selection.to)),
    anchorRect: () => (anchor.isConnected ? anchor.getBoundingClientRect() : null),
  })
}

document.addEventListener('keydown', (event) => {
  const state = linkPickerState
  if (!state || !linkPicker || linkPicker.hidden || event.isComposing) return
  const target = event.target
  const inField = state.source === 'field' && target === state.input
  const inProse = state.source !== 'field' && target instanceof Element && Boolean(target.closest('.ProseMirror'))
  if (!inField && !inProse) return
  switch (event.key) {
    case 'ArrowDown':
    case 'ArrowUp':
      // A list still searching has nothing to move through; the caret keeps
      // its keys.
      if (state.rows.length === 0) break
      event.preventDefault()
      event.stopPropagation()
      moveLinkPickerSelection(event.key === 'ArrowDown' ? 1 : -1)
      break
    case 'Enter':
    case 'Tab':
      if (state.rows.length === 0) break
      event.preventDefault()
      event.stopPropagation()
      choosePickerRow(state.index)
      break
    case 'Escape':
      // The first Escape closes the list and leaves the typing; in the field
      // a second one reaches Crepe and closes the field itself.
      event.preventDefault()
      event.stopPropagation()
      dismissLinkPicker()
      break
    default:
      break
  }
}, true)

document.addEventListener('input', (event) => {
  if (event.isComposing) return
  const field = linkFieldInput(event.target)
  if (field) refreshLinkFieldPicker(field)
}, true)

/// The `[[` (and `((`, and `/`) is looked for after every change to the
/// document or its selection, from the editor's own state. A DOM `input`
/// event is too early: ProseMirror reads typed text out of the DOM in a
/// mutation observer, so at the event the state still ends before the
/// keystroke and the brackets are not there yet to find.
const linkPickerPlugin = $prose(() => new Plugin({
  key: new PluginKey('foreverlm-link-picker'),
  view: () => ({ update: () => refreshCaretPickers(), destroy: () => hideLinkPicker() }),
}))

document.addEventListener('focusin', (event) => {
  const field = linkFieldInput(event.target)
  if (field) refreshLinkFieldPicker(field)
}, true)

document.addEventListener('focusout', (event) => {
  if (linkFieldInput(event.target) && linkPickerState?.source === 'field') hideLinkPicker()
}, true)

// ─── Reference cards ───────────────────────────────────────────────────────
// A line that is nothing but a link to the web — a reference under a research
// report, an item in a reading list — is drawn as a compact card: the title
// the writer gave the link, the address's domain, and what the library says
// about it. The Markdown stays an ordinary link, so the doc reads on every
// client and nothing new is stored; the card is presentation, recomputed from
// the document each time it changes. The editor tells the host which addresses
// the doc holds (`referencesChanged`) and the host answers with
// `setReferenceStatuses`: a reference already in the library carries a check
// that opens the source, one that is not offers Add to Sources, and with no
// answer at all — Web Studio today — the card stands on title and domain alone.
//
// A line that is nothing but a link to a library source — `[Title](foreverlm://
// source/<id>)`, the line a source dropped off the prose writes — is the same
// card, drawn the way the chat's Sources row draws that source: its picture,
// its title, and the library's metadata line under it. The host answers by id
// rather than by address, and a card whose source this library does not hold
// says so instead of offering Add to Sources, which has no address to add.

const referencePluginKey = new PluginKey('foreverlm-reference-cards')
let referenceStatuses = new Map()
let lastPostedReferenceHrefs = null
let referencePostTimer = null

/// The web address a link mark points at, or null for anything that is not a
/// destination on the web: the editor's own private addresses, mail, files.
function webReferenceHref(href) {
  try {
    const url = new URL(String(href ?? '').trim())
    const protocol = url.protocol.toLowerCase()
    if (protocol !== 'http:' && protocol !== 'https:') return null
    if (url.hostname.toLowerCase() === 'foreverlm.invalid') return null
    return String(href).trim()
  } catch {
    return null
  }
}

/// The page an address names: the address without its fragment, which is how
/// the library knows a source (`URLNormalizer` drops it too). An article's
/// `#ref-CR32` and `#Fig3` are two places in one page, and one source.
function referencePage(href) {
  try {
    const url = new URL(String(href ?? '').trim())
    url.hash = ''
    return url.href
  } catch {
    return String(href ?? '').trim()
  }
}

/// The address a reference card stands for: a web URL, or the stored form of a
/// library source's address for a line that is only a source link. The stored
/// form is what the host is asked about and what its answer is keyed by.
function referenceHref(href) {
  const web = webReferenceHref(href)
  if (web) return web
  const id = sourceID(href)
  return id ? `${sourceMarkdownPrefix}${encodeURIComponent(id)}` : null
}

/// Whether a card's address names a library source rather than the web.
function isSourceReference(href) {
  return String(href ?? '').startsWith(sourceMarkdownPrefix)
}

function referenceDomain(href) {
  if (isSourceReference(href)) return ''
  try {
    const host = new URL(href).hostname.toLowerCase()
    return host.startsWith('www.') ? host.slice(4) : host
  } catch {
    return ''
  }
}

// What may stand before the link and how a detail after it has to begin. A
// reference list is a list, and its lines are written every way a bibliography
// is: "[3] Title", "3. Title", "**S01 · Company post:** Title. January 2026
// methods and results; four donors." So in a list item the label before the
// link may be anything short that ends the way a label does — a colon, a dot
// separator, a dash, a bar, a closing bracket — and the detail after it may run
// to a few lines, as long as it opens with a separator rather than a word. A
// paragraph outside a list is held to the plain shape: a numeric label at most
// and a short detail, because a sentence that merely opens with a link would
// otherwise be taken for a reference. Prose continues with a word, not a
// separator, which is what keeps "[Cellarity](…) pairs transcriptomics with"
// a sentence in both cases.
const referenceNumericLabel = /^\s*(?:\[\d{1,3}\]|\d{1,3}[.)])?\s*$/
// The em dash is built from its code point rather than written: the website's
// copy check scans the served bundle for the character, a pattern is not copy,
// and esbuild turns a `\u2014` escape back into the character.
const emDash = String.fromCharCode(0x2014)
const referenceListLabel = new RegExp(`^\\s*(?:\\[\\d{1,3}\\]|\\d{1,3}[.)]|.{1,80}?[:·${emDash}–|\\])])?\\s*$`)
const referenceDetailOpening = new RegExp(`^\\s*[${emDash}–\\-,·(|;:.]`)
const referenceDetailLimit = 160
const referenceListDetailLimit = 400

/// The reference a text block is, or null. A reference is a paragraph holding
/// one link to the web, or to a library source, and nothing else that is not
/// text: an optional label before it and an optional detail after it, within
/// the shapes above.
function referenceInBlock(state, block) {
  if (block.node.type.name !== 'paragraph') return null
  const $position = state.doc.resolve(block.position)
  // A table cell holding one link and a few words — a trial id and its phase in
  // a column of trials — is a cell of the table, not a reference line: the
  // table is the list, and a card's tile, domain and control have no room in a
  // column (product owner, 2026-09-12: "this rendering looks bad"). The link stays a
  // link, as the margin cards already leave it.
  for (let depth = $position.depth; depth > 0; depth -= 1) {
    if (/table/i.test($position.node(depth).type.name)) return null
  }
  const parent = $position.parent
  const inList = /list_item|listItem/i.test(parent?.type?.name ?? '')
  let href = null
  let leading = ''
  let title = ''
  let detail = ''
  let titleTo = block.from
  let offset = block.from
  for (let index = 0; index < block.node.childCount; index += 1) {
    const child = block.node.child(index)
    offset += child.nodeSize
    // An image, a hard break or inline math is not a reference line.
    if (!child.isText) return null
    const mark = child.marks.find((candidate) => candidate.type.name === 'link')
    if (mark) {
      const markHref = referenceHref(mark.attrs?.href)
      if (!markHref) return null
      // A second link, or the same one resumed after other words: a sentence.
      if (href && (href !== markHref || detail)) return null
      href = markHref
      title += child.text
      titleTo = offset
    } else if (!href) {
      leading += child.text
    } else {
      detail += child.text
    }
  }
  if (!href || !title.trim()) return null
  if (!(inList ? referenceListLabel : referenceNumericLabel).test(leading)) return null
  const detailLimit = inList ? referenceListDetailLimit : referenceDetailLimit
  if (detail.trim() && (detail.length > detailLimit || !referenceDetailOpening.test(detail))) return null
  return { href, title: title.trim(), detailFrom: titleTo, detailTo: block.to, block }
}

function referenceStatus(href) {
  return referenceStatuses.get(href) ?? null
}

/// An address the tile may hand to an `<img>`: fetched over the web, or an
/// image the host embedded. Anything else is dropped rather than loaded.
function webImageAddress(value) {
  const address = value == null ? '' : String(value)
  if (/^https?:\/\//i.test(address)) return address
  if (/^data:image\//i.test(address)) return address
  return ''
}

// The glyph a tile draws when it has no picture: the source family's mark for
// a source in the library, a page for a preview that found none, a link for a
// card the host has not answered.
const referenceGlyphPaths = {
  document: '<path d="M7 3.5h6.5L18 8v12.5H7z"/><path d="M13.5 3.5V8H18"/><path d="M9.5 12.5h5M9.5 15.5h5"/>',
  video: '<rect x="4" y="6" width="16" height="12" rx="2"/><path d="M10.5 9.5v5l4-2.5z"/>',
  podcast: '<path d="M5 13a7 7 0 0 1 14 0"/><path d="M5 13v3.5a1.5 1.5 0 0 0 1.5 1.5H8v-6H6.5A1.5 1.5 0 0 0 5 13z"/><path d="M19 13v3.5a1.5 1.5 0 0 1-1.5 1.5H16v-6h1.5a1.5 1.5 0 0 1 1.5 1z"/>',
  book: '<path d="M5 5.5A1.5 1.5 0 0 1 6.5 4H18v14.5H6.5A1.5 1.5 0 0 0 5 20z"/><path d="M5 18.5V5.5"/><path d="M18 18.5H6.5A1.5 1.5 0 0 0 5 20"/>',
  link: '<path d="M10 14a3.5 3.5 0 0 0 4.95 0l2.5-2.5a3.5 3.5 0 0 0-4.95-4.95L11.5 7.5"/><path d="M14 10a3.5 3.5 0 0 0-4.95 0l-2.5 2.5a3.5 3.5 0 0 0 4.95 4.95l1-1"/>',
}

function referenceGlyph(kind, state, source = false) {
  const name = state === 'unknown'
    ? (source ? 'document' : 'link')
    : kind === 'video' ? 'video'
      : kind === 'podcast' ? 'podcast'
        : kind === 'book' || kind === 'course' ? 'book'
          : 'document'
  return `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${referenceGlyphPaths[name]}</svg>`
}

/// The card's leading tile: the source's picture when the host has one (the
/// library's own artwork for a saved source, a page's `og:image` for one it does
/// not hold), else the site's icon, small, else the glyph. A picture that fails
/// to load steps down the same ladder, so the tile is never blank.
function referenceThumbnail(href, status) {
  const tile = document.createElement('span')
  tile.className = 'artifact-reference-thumbnail'
  tile.contentEditable = 'false'
  tile.setAttribute('aria-hidden', 'true')
  const state = status?.state ?? 'unknown'
  const kind = status?.kind ?? ''
  if (kind) tile.dataset.kind = kind
  const showGlyph = () => {
    tile.replaceChildren()
    tile.classList.add('is-glyph')
    tile.innerHTML = referenceGlyph(kind, state, isSourceReference(href))
  }
  const picture = status?.thumbnailURL ?? ''
  const icon = status?.iconURL ?? ''
  if (!picture && !icon) {
    showGlyph()
    return tile
  }
  const image = document.createElement('img')
  image.alt = ''
  image.decoding = 'async'
  image.referrerPolicy = 'no-referrer'
  let showing = picture ? 'picture' : 'icon'
  image.className = `artifact-reference-${showing}`
  image.src = picture || icon
  image.addEventListener('error', () => {
    if (showing === 'picture' && icon) {
      showing = 'icon'
      image.className = 'artifact-reference-icon'
      image.src = icon
      return
    }
    showGlyph()
  })
  tile.append(image)
  return tile
}

/// A source card's second line: what the library says about the source — a
/// paper's author · venue · year, the chat card's line otherwise — under the
/// title, the way the chat's Sources row writes it. Only when the line itself
/// carries no detail of its own; a writer's detail is theirs.
function referenceMeta(status) {
  const meta = document.createElement('span')
  meta.className = 'artifact-reference-meta'
  meta.contentEditable = 'false'
  meta.textContent = status.detail
  return meta
}

/// The card's trailing control: the domain, then what the library says. It is
/// not editable — the caret has no business in it — and a press on it leaves
/// the editor's selection where it was.
function referenceControl(href, status) {
  const control = document.createElement('span')
  control.className = 'artifact-reference-control'
  control.contentEditable = 'false'
  // A press on the control must not move the caret or take focus from the
  // prose; cancelling mousedown does that and still lets the click through.
  control.addEventListener('mousedown', (event) => event.preventDefault())

  // A source card has no site to name; its trailing edge holds the library's
  // answer alone.
  const domainName = referenceDomain(href)
  if (domainName) {
    const domain = document.createElement('span')
    domain.className = 'artifact-reference-domain'
    domain.textContent = domainName
    control.append(domain)
  }

  const action = referenceAction(href, status)
  if (action) control.append(action)
  return control
}

const referenceCheckSVG = '<svg viewBox="0 0 12 12" width="12" height="12"><path d="M2.4 6.4l2.4 2.4 4.8-5.2" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>'
const referenceRequestSVG = '<svg viewBox="0 0 12 12" width="12" height="12"><path d="M6 1.6v6.2M3.2 4.6 6 1.8l2.8 2.8M2 9.4h8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>'
const referencePlusSVG = '<svg viewBox="0 0 12 12" width="12" height="12"><path d="M6 2.2v7.6M2.2 6h7.6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>'

/// What the library says about an address, as the one control a card offers:
/// in the library, a filled check that opens the source; not in the library,
/// Add to Sources; a wait while the import runs; nothing while the host has not
/// answered. `compact` draws Add to Sources as a plus with the words as its
/// label, for the margin cards, whose width the words would not fit.
function referenceAction(href, status, compact = false) {
  const state = status?.state ?? 'unknown'
  if (state === 'inLibrary') {
    const open = document.createElement('button')
    open.type = 'button'
    open.dataset.role = 'open'
    open.title = 'In your library — open in Reader'
    open.setAttribute('aria-label', 'In your library. Open in Reader')
    const check = document.createElement('span')
    check.className = 'artifact-reference-check'
    check.setAttribute('aria-hidden', 'true')
    check.innerHTML = referenceCheckSVG
    open.append(check)
    open.addEventListener('click', (event) => {
      event.stopPropagation()
      post('openSourceRequested', { href, sourceID: status?.sourceID ?? '' })
    })
    return open
  }
  if (state === 'adding') {
    const pending = document.createElement('span')
    pending.className = 'artifact-reference-pending'
    pending.textContent = compact ? '…' : 'Adding…'
    if (compact) pending.title = 'Adding to Sources'
    return pending
  }
  if (state === 'requested') {
    const waiting = document.createElement('span')
    waiting.className = 'artifact-reference-pending'
    waiting.textContent = compact ? '…' : 'Requested'
    waiting.title = status?.message || 'Requested from the team'
    return waiting
  }
  if (state === 'requestable' || state === 'fulfillable') {
    // A team Doc's card the import could not fill: ask the team for the
    // source, or, when this Mac holds it, answer a teammate's request.
    const isShare = state === 'fulfillable'
    const button = document.createElement('button')
    button.type = 'button'
    button.dataset.role = isShare ? 'share' : 'request'
    const words = isShare ? 'Share' : 'Request from team'
    const hint = isShare
      ? `${status?.message || 'Requested by a teammate'} — share your copy with the team`
      : `${status?.message ? status.message + ' ' : ''}Ask the team for this source`
    if (compact) {
      button.classList.add('is-compact')
      button.setAttribute('aria-label', words)
      button.title = hint
      const glyph = document.createElement('span')
      glyph.className = 'artifact-reference-plus'
      glyph.setAttribute('aria-hidden', 'true')
      glyph.innerHTML = isShare ? referenceCheckSVG : referenceRequestSVG
      button.append(glyph)
    } else {
      button.textContent = words
      button.title = hint
    }
    button.addEventListener('click', (event) => {
      event.stopPropagation()
      referenceStatuses.set(href, { state: 'adding', sourceID: status?.sourceID ?? '', message: '' })
      refreshReferenceDecorations()
      post(isShare ? 'fulfilReferenceRequested' : 'requestReferenceRequested', { href, requestID: status?.sourceID ?? '' })
    })
    return button
  }
  if ((state === 'absent' || state === 'failed') && isSourceReference(href)) {
    // A private address names a source by id; there is nothing to fetch and
    // add, so the card says what the library says and offers nothing.
    const missing = document.createElement('span')
    missing.className = 'artifact-reference-pending'
    missing.textContent = compact ? emDash : 'Not in this library'
    missing.title = 'Not in this library'
    return missing
  }
  if (state === 'absent' || state === 'failed') {
    const add = document.createElement('button')
    add.type = 'button'
    add.dataset.role = 'add'
    if (compact) {
      add.classList.add('is-compact')
      add.setAttribute('aria-label', 'Add to Sources')
      add.title = state === 'failed' && status?.message ? status.message : 'Add to Sources'
      const plus = document.createElement('span')
      plus.className = 'artifact-reference-plus'
      plus.setAttribute('aria-hidden', 'true')
      plus.innerHTML = referencePlusSVG
      add.append(plus)
    } else {
      add.textContent = 'Add to Sources'
      if (state === 'failed' && status?.message) add.title = status.message
    }
    add.addEventListener('click', (event) => {
      event.stopPropagation()
      referenceStatuses.set(href, { state: 'adding', sourceID: '', message: '' })
      refreshReferenceDecorations()
      post('addReferenceRequested', { href })
    })
    return add
  }
  return null
}

// ─── Margin cards ──────────────────────────────────────────────────────────
// A link inside a sentence — the paper a claim rests on, the company page a
// profile draws from — is a source the writer is standing on just as much as a
// reference line is, and the reader deciding whether to add it wants to see it
// where it is cited, not two hundred lines down in a reference list. So every
// paragraph holding web links gets a stack of cards in the right margin,
// beside the paragraph, each drawn the way the Sources sidebar draws a row: the
// picture, the title, a quieter line of what it is (author · venue · year for a
// paper, the site for a page) and, at the trailing edge, the library's answer —
// a check that opens the source, or a plus that adds it. The cards are
// presentation: the Markdown keeps its inline links, and nothing is stored.
//
// The margin is a column of its own, not the paragraph's box, so a card is
// positioned by a layout pass rather than by the paragraph alone: every card
// sits at the top of its paragraph unless the stack above runs into it, in
// which case it takes the first free row below. Below a pane width that cannot
// hold the prose and the column together the cards are not drawn; the links are
// still in the prose, where they always were.

/// The distinct web pages a paragraph cites in sentences, in reading order,
/// each with the first address it is cited by and that link's words:
/// `[{ href, page, text }]`. A card is a source, so two links into one page
/// (`#Fig3` and `#Fig4` of one article) are one card. A reference line is not
/// a citation — it has its own card — and a table cell has no margin to carry
/// one, so both answer with nothing.
function citedLinksInBlock(state, block) {
  if (block.node.type.name !== 'paragraph') return []
  const $position = state.doc.resolve(block.position)
  for (let depth = $position.depth; depth > 0; depth -= 1) {
    if (/table/i.test($position.node(depth).type.name)) return []
  }
  const byPage = new Map()
  let previousHref = null
  block.node.forEach((child) => {
    if (!child.isText) { previousHref = null; return }
    const mark = child.marks.find((candidate) => candidate.type.name === 'link')
    const href = mark ? webReferenceHref(mark.attrs?.href) : null
    if (!href) { previousHref = null; return }
    const page = referencePage(href)
    const cited = byPage.get(page)
    if (!cited) byPage.set(page, { href, page, text: child.text })
    // One link split into two text nodes by a second mark — a bold word inside
    // the title — is one run of words; the same page cited again later in the
    // paragraph is a repeat, and its words are not appended.
    else if (previousHref === href && cited.href === href) cited.text += child.text
    previousHref = href
  })
  return [...byPage.values()].map((cited) => ({ href: cited.href, page: cited.page, text: cited.text.trim() }))
}

/// Which web pages each section already lists as reference cards, keyed by
/// the index of the heading that opens the section (0 before the first
/// heading). A source that has its own card a few lines under the paragraph
/// that cites it — the shape a report's per-company reference list takes — is
/// not repeated in the margin; a References list at the end of the doc is
/// another section, and leaves every margin card standing.
function referencePagesBySection(state, blocks) {
  const bySection = new Map()
  let section = 0
  for (const block of blocks) {
    if (block.node.type.name === 'heading') { section += 1; continue }
    const reference = referenceInBlock(state, block)
    if (!reference) continue
    if (!bySection.has(section)) bySection.set(section, new Set())
    bySection.get(section).add(referencePage(reference.href))
  }
  return bySection
}

/// One margin card, drawn like a Sources sidebar row. A card in the library
/// opens the source when pressed anywhere; a card the host has not answered, or
/// whose source the library does not hold, is inert except for its control.
/// Hovering a card underlines the words in the paragraph that cite it, so the
/// reader can tell which of a paragraph's three cards belongs to which claim.
function marginCard(cited, status) {
  const card = document.createElement('div')
  card.className = 'artifact-margin-card'
  const state = status?.state ?? 'unknown'
  card.dataset.referenceState = state
  card.dataset.href = cited.href

  const tile = referenceThumbnail(cited.href, status)
  const body = document.createElement('span')
  body.className = 'artifact-margin-card-body'
  const title = document.createElement('span')
  title.className = 'artifact-margin-card-title'
  title.textContent = status?.title || cited.text || referenceDomain(cited.href)
  const detail = document.createElement('span')
  detail.className = 'artifact-margin-card-detail'
  detail.textContent = status?.detail || referenceDomain(cited.href)
  body.append(title, detail)
  card.append(tile, body)

  const action = referenceAction(cited.href, status, true)
  if (action) {
    const control = document.createElement('span')
    control.className = 'artifact-margin-card-action'
    control.append(action)
    card.append(control)
  }

  if (state === 'inLibrary') {
    card.classList.add('is-openable')
    card.setAttribute('role', 'button')
    card.tabIndex = 0
    card.title = 'Open in Reader'
    const open = () => post('openSourceRequested', { href: cited.href, sourceID: status?.sourceID ?? '' })
    card.addEventListener('click', open)
    card.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault()
        open()
      }
    })
  } else {
    card.title = cited.href
  }

  const citedAnchors = () => {
    const paragraph = card.closest('.artifact-cited')
    if (!paragraph) return []
    return [...paragraph.querySelectorAll('a[href]')].filter((anchor) => referencePage(anchor.getAttribute('href')) === cited.page)
  }
  card.addEventListener('mouseenter', () => {
    for (const anchor of citedAnchors()) anchor.classList.add('artifact-cited-active')
  })
  card.addEventListener('mouseleave', () => {
    for (const anchor of citedAnchors()) anchor.classList.remove('artifact-cited-active')
  })
  return card
}

// The pane width below which there is no room for a margin column beside a
// readable prose column: the same number as the stylesheet's narrow tier and
// `marginColumnBreakpoint` in ArtifactViews.swift. Below it the cards flow
// under their paragraph instead — a Docs pane beside Chat and Sources on a
// 2560-point display is about 620 points, and that is the layout the reports
// are read in, so "no cards" was never an acceptable narrow tier.
const marginColumnBreakpoint = 790

// The margin column's own width: a 240px card and a 20px gutter, the same
// numbers as the stylesheet's `--artifact-margin-card-width` and
// `--artifact-margin-gutter` and `marginColumnWidth` in ArtifactViews.swift.
const marginColumnWidth = 260

// The prose column's cap in CSS pixels, `Infinity` when the page fills the
// pane. The host sets it through `setPageWidth`; until it does, the stylesheet's
// default stands.
let pageMaxWidth = 760

function setPageWidth(width) {
  const cap = typeof width === 'number' && Number.isFinite(width) && width > 0 ? width : Infinity
  pageMaxWidth = cap
  document.documentElement.style.setProperty(
    '--artifact-page-width',
    Number.isFinite(cap) ? `${cap}px` : '100%'
  )
  applyMarginTier()
  scheduleMarginCardLayout()
}

// Whether margin cards are drawn at all. A reader who wants the prose alone
// turns them off (the host's `setMarginCardsShown`): no stack beside or below
// any paragraph, no column for the page to make room for, and the cited words
// stay quiet in the prose, where the links always were. A reference line is
// the doc's own paragraph, not a card beside one, and keeps its card.
let marginCardsShown = true

function setMarginCardsShown(shown) {
  const next = shown !== false
  if (next === marginCardsShown) return
  marginCardsShown = next
  refreshReferenceDecorations()
  scheduleMarginCardLayout()
}

function marginCardTier() {
  return window.innerWidth >= marginColumnBreakpoint ? 'margin' : 'inline'
}

/// Where the page sits when it has a margin column: `wide` when the pane holds
/// the full page and the column side by side, `medium` when the page has to
/// yield the column's width, `inline` when there is no column at all. The
/// stylesheet reads the answer from the body, because the wide threshold moves
/// with the page width the host chose and a media query cannot follow it.
function marginTier() {
  const width = window.innerWidth
  if (width < marginColumnBreakpoint) return 'inline'
  return width >= pageMaxWidth + marginColumnWidth ? 'wide' : 'medium'
}

function applyMarginTier() {
  const tier = marginTier()
  if (document.body.dataset.marginTier !== tier) document.body.dataset.marginTier = tier
}

let lastMarginCardTier = marginCardTier()

/// The stack of cards for one paragraph: beside it in the margin, or below it
/// (`inline`) when the pane cannot hold a margin column.
function marginCards(citedLinks, inline = false) {
  const aside = document.createElement('aside')
  aside.className = 'artifact-margin-cards'
  aside.dataset.tier = inline ? 'inline' : 'margin'
  aside.contentEditable = 'false'
  aside.setAttribute('aria-label', 'Sources cited in this paragraph')
  // A press in the margin must not move the caret or take focus from the
  // prose; cancelling mousedown does that and still lets the click through.
  aside.addEventListener('mousedown', (event) => event.preventDefault())
  for (const cited of citedLinks) aside.append(marginCard(cited, referenceStatus(cited.href)))
  return aside
}

let marginLayoutFrame = null

/// Place every margin stack: at the top of its paragraph, or at the first row
/// below the stack above it when the two would overlap, and all in one column
/// past the page's right edge whatever the paragraph's own indentation. The
/// pass reads every rect first and writes every position after, so it forces
/// one layout, not one per card. A stack whose paragraph is folded away, or
/// whose column the pane is too narrow to show, is left where CSS put it.
function layoutMarginCards() {
  marginLayoutFrame = null
  const root = document.querySelector('.milkdown .editor')
  if (!root) return
  const asides = [...root.querySelectorAll('.artifact-margin-cards')]
  document.body.classList.toggle('has-margin-cards', asides.length > 0)
  applyMarginTier()
  if (asides.length === 0) return
  // The pane crossed the breakpoint since the stacks were written: they belong
  // at the other end of their paragraphs now, which is a decoration change.
  const tier = marginCardTier()
  if (tier !== lastMarginCardTier) {
    lastMarginCardTier = tier
    refreshReferenceDecorations()
    return
  }
  if (tier === 'inline') {
    for (const aside of asides) {
      aside.style.left = ''
      aside.style.top = ''
    }
    return
  }
  const rootStyle = getComputedStyle(root)
  if (getComputedStyle(asides[0]).position !== 'absolute') return
  const gutter = parseFloat(rootStyle.getPropertyValue('--artifact-margin-gutter')) || 20
  const gap = parseFloat(rootStyle.getPropertyValue('--artifact-margin-gap')) || 10
  const rootRect = root.getBoundingClientRect()
  const columnLeft = rootRect.right - (parseFloat(rootStyle.paddingRight) || 0) + gutter
  const measured = asides.map((aside) => {
    const block = aside.parentElement
    const blockRect = block?.getBoundingClientRect()
    return { aside, blockRect, height: aside.offsetHeight }
  })
  let nextFreeTop = -Infinity
  for (const { aside, blockRect, height } of measured) {
    if (!blockRect || blockRect.height === 0) continue
    const offset = Math.max(0, nextFreeTop - blockRect.top)
    aside.style.left = `${columnLeft - blockRect.left}px`
    aside.style.top = `${offset}px`
    nextFreeTop = blockRect.top + offset + height + gap
  }
}

function scheduleMarginCardLayout() {
  if (marginLayoutFrame != null) return
  // A hidden document — a Docs pane in an occluded window — gets no animation
  // frames, and would otherwise come back into view with its stacks wherever
  // the last frame left them; a timer runs there and the page is right when
  // it is next shown.
  marginLayoutFrame = document.hidden
    ? setTimeout(layoutMarginCards, 0)
    : requestAnimationFrame(layoutMarginCards)
}

/// Every card in the document, as decorations: the paragraph takes the card
/// class and the library's answer, the detail after the title takes its own
/// class so it can read quieter, and a widget at the head of the line holds the
/// control. Widgets are keyed by address and state, so a card whose answer has
/// not changed keeps its DOM across every keystroke elsewhere.
function referenceDecorations(state) {
  const decorations = []
  const hrefs = []
  let citedBlocks = 0
  const blocks = textBlocks(state)
  const listedBySection = referencePagesBySection(state, blocks)
  let section = 0
  for (const block of blocks) {
    if (block.node.type.name === 'heading') { section += 1; continue }
    const reference = referenceInBlock(state, block)
    if (!reference) {
      // Not a reference line: a paragraph citing the web in its sentences gets
      // its stack of margin cards, keyed on every address and answer it holds
      // so a stack whose answers have not changed keeps its DOM. The paragraph
      // takes the cited class either way, so its links read quietly; a source
      // the section already lists as a card is not repeated in the margin.
      const citedAll = citedLinksInBlock(state, block)
      if (citedAll.length === 0) continue
      // Cards turned off: the links still read quietly, and their addresses
      // are not reported, so the host fetches no preview for a card nobody
      // sees; turning the cards back on reports them and the host answers.
      if (!marginCardsShown) {
        decorations.push(Decoration.node(block.position, block.position + block.node.nodeSize, {
          class: 'artifact-cited',
        }))
        continue
      }
      const listed = listedBySection.get(section)
      const cited = listed ? citedAll.filter(({ page }) => !listed.has(page)) : citedAll
      for (const { href } of citedAll) hrefs.push(href)
      if (cited.length === 0) {
        decorations.push(Decoration.node(block.position, block.position + block.node.nodeSize, {
          class: 'artifact-cited',
        }))
        continue
      }
      const key = cited.map(({ href, text }) => {
        const status = referenceStatus(href)
        return `${href}\x00${text}\x00${status?.state ?? ''}\x00${status?.sourceID ?? ''}\x00${status?.kind ?? ''}\x00${(status?.thumbnailURL ?? '').length}:${(status?.thumbnailURL ?? '').slice(0, 96)}\x00${status?.iconURL ?? ''}\x00${status?.title ?? ''}\x00${status?.detail ?? ''}`
      }).join('\x01')
      citedBlocks += 1
      decorations.push(Decoration.node(block.position, block.position + block.node.nodeSize, {
        class: 'artifact-cited',
      }))
      // In the margin the stack is written at the head of the paragraph and
      // positioned beside it; in a pane too narrow for a margin column it is
      // written after the paragraph's last word and flows below the text.
      const inline = marginCardTier() === 'inline'
      decorations.push(Decoration.widget(inline ? block.to : block.from, () => marginCards(cited, inline), {
        side: inline ? 1 : -3,
        key: `margin-cards:${inline ? 'inline' : 'margin'}:${key}`,
        ignoreSelection: true,
        stopEvent: () => true,
      }))
      continue
    }
    hrefs.push(reference.href)
    const status = referenceStatus(reference.href)
    const stateName = status?.state ?? 'unknown'
    const sourceCard = isSourceReference(reference.href)
    decorations.push(Decoration.node(block.position, block.position + block.node.nodeSize, {
      class: sourceCard ? 'artifact-reference artifact-source-card' : 'artifact-reference',
      'data-reference-state': stateName,
    }))
    if (reference.detailTo > reference.detailFrom) {
      decorations.push(Decoration.inline(reference.detailFrom, reference.detailTo, {
        class: 'artifact-reference-detail',
      }))
    } else if (sourceCard && status?.detail) {
      // The library's line under the title, written after the paragraph's
      // last character so typing at the end of the title stays ahead of it.
      decorations.push(Decoration.widget(block.to, () => referenceMeta(status), {
        side: 1,
        key: `reference-meta:${status.detail}:${reference.href}`,
        ignoreSelection: true,
        stopEvent: () => true,
      }))
    }
    // The tile is written at the head of the line and positioned at the card's
    // leading edge, out of the text flow; the card's own padding makes room.
    const pictureKey = `${status?.kind ?? ''}:${(status?.thumbnailURL ?? '').length}:${(status?.thumbnailURL ?? '').slice(0, 96)}:${status?.iconURL ?? ''}`
    decorations.push(Decoration.widget(block.from, () => referenceThumbnail(reference.href, status), {
      side: -2,
      key: `reference-thumbnail:${stateName}:${pictureKey}:${reference.href}`,
      ignoreSelection: true,
      stopEvent: () => true,
    }))
    // The control is written at the head of the line and floated to its trailing
    // edge, so the label, title and detail keep flowing as one run of text
    // around it and a long entry wraps under it at full width.
    decorations.push(Decoration.widget(block.from, () => referenceControl(reference.href, status), {
      side: -1,
      key: `reference:${stateName}:${status?.sourceID ?? ''}:${reference.href}`,
      ignoreSelection: true,
      // ProseMirror otherwise handles a mousedown inside the widget as a press
      // on the document — it re-renders around it and the button never sees
      // the click. Events inside the control are the control's own.
      stopEvent: () => true,
    }))
  }
  scheduleReferencesChanged(hrefs, citedBlocks > 0)
  return DecorationSet.create(state.doc, decorations)
}

/// Tell the host which addresses the doc holds, and whether any of them stand
/// in the margin — the host lays the page's title on the same column as the
/// prose, and the prose moves over when there is a margin column beside it —
/// once per distinct answer and a beat after the last change, so typing inside
/// a title does not send a message per keystroke.
function scheduleReferencesChanged(hrefs, marginColumn) {
  const distinct = [...new Set(hrefs)]
  const serialized = JSON.stringify({ hrefs: distinct, marginColumn })
  if (serialized === lastPostedReferenceHrefs) return
  if (referencePostTimer != null) clearTimeout(referencePostTimer)
  referencePostTimer = setTimeout(() => {
    referencePostTimer = null
    if (serialized === lastPostedReferenceHrefs) return
    lastPostedReferenceHrefs = serialized
    post('referencesChanged', { hrefs: distinct, marginColumn })
  }, 150)
}

function refreshReferenceDecorations() {
  const view = activeEditorView()
  if (!view) return
  view.dispatch(view.state.tr.setMeta(referencePluginKey, true))
}

/// The host's answer for each address:
/// `{ [href]: { state, sourceID, message, kind, thumbnailURL, iconURL, title, detail } }`
/// with state one of `inLibrary`, `absent`, `adding`, `failed`, `requestable`,
/// `requested`, `fulfillable` (the last three on a team Doc: ask the team for a
/// source, a request standing, a request this Mac can answer; for those
/// `sourceID` carries the request id); `kind` names the
/// source family (or `page` / `pdf` for a preview), `thumbnailURL` is the card's
/// picture (an `https:` address or a `data:` image) and `iconURL` the site's
/// mark for a card without one. `title` and `detail` are what a margin card
/// says about the source — the library's title and metadata line for a saved
/// source, the page's own for one it does not hold; a card without them stands
/// on the words that cite it and the site. The whole map is replaced, so a host
/// that stops mentioning an address returns its card to the quiet form.
function setReferenceStatuses(statuses) {
  referenceStatuses = new Map(
    Object.entries(statuses ?? {}).map(([href, status]) => [
      String(href),
      {
        state: String(status?.state ?? 'unknown'),
        sourceID: status?.sourceID ? String(status.sourceID) : '',
        message: status?.message ? String(status.message) : '',
        kind: status?.kind ? String(status.kind) : '',
        thumbnailURL: webImageAddress(status?.thumbnailURL),
        iconURL: webImageAddress(status?.iconURL),
        title: status?.title ? String(status.title).trim() : '',
        detail: status?.detail ? String(status.detail).trim() : '',
      },
    ])
  )
  refreshReferenceDecorations()
}

const referenceCardsPlugin = $prose(() => new Plugin({
  key: referencePluginKey,
  state: {
    init: (_config, state) => referenceDecorations(state),
    apply: (tr, decorations, _previous, state) => (
      tr.docChanged || tr.getMeta(referencePluginKey) ? referenceDecorations(state) : decorations
    ),
  },
  props: {
    decorations: (state) => referencePluginKey.getState(state),
  },
  // Every update can move a paragraph — a keystroke above it, a card's answer
  // landing — so the margin is re-laid on the next frame; the pass is a rect
  // read per stack, cheap even for a report with a hundred and fifty.
  view: () => ({ update: scheduleMarginCardLayout, destroy: () => {} }),
}))

// ─── The notes graph ───────────────────────────────────────────────────────
// Roam Research's way of taking notes, in Docs (docs/notes-graph-design.md):
// any block can be referenced from anywhere (`((id))`) or embedded
// (`{{embed: ((id))}}`), a page is named by its title (`[[Title]]`, `#tag`),
// and the foot of every page lists what points at it. Everything is ordinary
// Markdown; this section draws it.
//
// A block's id, ` ^a1b2c3d4e` at the end of its text in the Markdown, is not
// text here at all: the parser takes it off the paragraph or heading and
// keeps it as the block's `blockID` attribute, and the serializer writes it
// back as the last thing in the block. So it is never drawn, the caret can
// never stand in it or after it, and words typed at the end of a block go
// before it, by construction. What the editor still has to look after is that
// an id stays with its block and stands once: a block split in two keeps it in
// the half with the words it began with, a paste never copies another block's
// id, and a block turned into a heading keeps it (`blockIDPlugin`).
//
// The host hands over what it knows (`setGraphContext`, `setBlocks`, ...) and
// is asked what the editor lacks (`blocksRequested`, ...), per PROTOCOL.md. A
// host that sends nothing (Web Studio today) leaves the editor as it was: the
// ids still hidden, every reference readable as typed, no page foot.

function emptyGraph() {
  return {
    active: false,
    docID: '',
    isDailyNote: false,
    allowsDates: false,
    blocks: new Map(),
    titles: new Map(),
    refCounts: new Map(),
  }
}

let graph = emptyGraph()
/// Blocks the host answered `blocksRequested` with, and blocks the editor has
/// just referenced from the `((` list, which read from the search's answer
/// until the host's own context names them (`provisionalBlockIDs`).
let fetchedBlocks = new Map()
let provisionalBlockIDs = new Set()
/// Ids the host was asked about and answered without: drawn as missing.
let missingBlockIDs = new Set()
let requestedBlockIDs = new Set()
let pendingBlockRequest = new Set()
let blockRequestTimer = null
/// Bumped whenever what the graph knows changes: a drawn reference's HTML is
/// made again then (`renderedSnippet`), and its DOM is replaced only when the
/// HTML comes out different.
let graphGeneration = 0
let thisDocTitle = ''
let editorFocused = false
let drawingEveryReference = false

function normalizedBlock(value, blockID) {
  const block = value && typeof value === 'object' ? value : {}
  return {
    docID: String(block.docID ?? ''),
    docTitle: String(block.docTitle ?? ''),
    key: String(block.key ?? ''),
    kind: String(block.kind ?? 'paragraph'),
    blockID: isBlockID(block.blockID) ? block.blockID : blockID,
    markdown: String(block.markdown ?? ''),
    plainText: String(block.plainText ?? ''),
    breadcrumbs: Array.isArray(block.breadcrumbs) ? block.breadcrumbs.map((crumb) => String(crumb ?? '')) : [],
    childrenMarkdown: String(block.childrenMarkdown ?? ''),
    line: Number(block.line) || 0,
  }
}

/// What the graph says about a block: the block, `null` when the host has
/// said there is none, `undefined` while nobody has answered.
function graphBlock(blockID) {
  if (graph.blocks.has(blockID)) return graph.blocks.get(blockID)
  if (fetchedBlocks.has(blockID)) return fetchedBlocks.get(blockID)
  if (missingBlockIDs.has(blockID)) return null
  return undefined
}

const inlineMarkdownCache = new WeakMap()

/// A text block's own words as inline Markdown, for drawing a reference to a
/// block of this doc from the words as they are now rather than as last
/// saved. Nodes never change, so the answer is kept per node.
function inlineMarkdownOf(node) {
  if (inlineMarkdownCache.has(node)) return inlineMarkdownCache.get(node)
  let markdown = node.textContent
  try {
    const serialize = editor.editor.action((ctx) => ctx.get(serializerCtx))
    const { schema } = node.type
    const paragraph = schema.nodes.paragraph.create(null, node.content)
    markdown = markdownForStorage(serialize(schema.topNodeType.create(null, [paragraph]))).trim()
  } catch {
    // The node's plain words, then; a reference still reads.
  }
  inlineMarkdownCache.set(node, markdown)
  return markdown
}

/// A block of this doc by its id, from the document being edited.
function liveBlock(blockID, liveBlocks = null) {
  let found = liveBlocks?.get(blockID) ?? null
  if (!liveBlocks) {
    const view = foldEditorView()
    view?.state.doc.descendants((node, pos) => {
      if (found) return false
      if (!node.isTextblock) return true
      if (node.attrs?.blockID === blockID) found = { node, pos }
      return false
    })
  }
  if (!found) return null
  const known = graph.blocks.get(blockID)
  return {
    ...normalizedBlock(known, blockID),
    docID: graph.docID,
    docTitle: known?.docTitle || thisDocTitle,
    markdown: inlineMarkdownOf(found.node),
    plainText: found.node.textContent,
  }
}

function resolvedBlock(blockID, liveBlocks = null) {
  return liveBlock(blockID, liveBlocks) ?? graphBlock(blockID)
}

/// Whether a title names a page: true, false, or null without a graph.
function pageExists(title) {
  if (!graph.active) return null
  return titleNamesPage(title)
}

/// How a snippet (a reference's words, an embed, the page foot) resolves the
/// grammar it holds.
function graphSnippetOptions() {
  return {
    block: (blockID) => resolvedBlock(blockID),
    pageExists,
    onUnknownBlock: (blockID) => {
      if (graph.active) scheduleBlocksRequest([blockID])
    },
  }
}

/// Ask the host for the blocks the page shows references to and holds no
/// words for, a batch at a time and each id once.
function scheduleBlocksRequest(blockIDs) {
  for (const blockID of blockIDs) {
    if (!requestedBlockIDs.has(blockID) && graphBlock(blockID) === undefined) pendingBlockRequest.add(blockID)
  }
  if (pendingBlockRequest.size === 0 || blockRequestTimer != null) return
  blockRequestTimer = setTimeout(() => {
    blockRequestTimer = null
    const ids = [...pendingBlockRequest].filter((blockID) => !requestedBlockIDs.has(blockID) && graphBlock(blockID) === undefined)
    pendingBlockRequest = new Set()
    if (!graph.active || ids.length === 0) return
    for (const blockID of ids) requestedBlockIDs.add(blockID)
    post('blocksRequested', { blockIDs: ids })
  }, 40)
}

function hashString(value) {
  let hash = 2166136261
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0).toString(36)
}

function blockSignature(block) {
  if (block === undefined) return 'unknown'
  if (block === null) return 'missing'
  return hashString(`${block.kind}\u0000${block.markdown}\u0000${block.docTitle}\u0000${block.childrenMarkdown}\u0000${block.breadcrumbs.join('\u0001')}`)
}

/// A drawn reference's or embed's HTML, kept until the graph changes: drawing
/// runs after every keystroke, and most references read as they did. The
/// widget's key is the HTML's own, so a save that changes nothing a reference
/// shows leaves its DOM alone.
const renderedSnippets = new Map()

function renderedSnippet(kind, blockID, block, render) {
  const key = `${kind}\u0000${blockID}\u0000${graphGeneration}\u0000${blockSignature(block)}`
  let html = renderedSnippets.get(key)
  if (html == null) {
    if (renderedSnippets.size > 2000) renderedSnippets.clear()
    html = render()
    renderedSnippets.set(key, html)
  }
  return html
}

// ─── Block ids in the schema ────────────────────────────────────────────────

/// Whether a node is a block that can carry an id: a paragraph or a heading.
function carriesBlockID(node) {
  return Boolean(node?.type?.spec?.attrs && Object.prototype.hasOwnProperty.call(node.type.spec.attrs, 'blockID'))
}

/// Whether the block at `pos` may be given an id: a paragraph or heading
/// that is not a table's cell, which the grammar does not count as a block.
function canTakeBlockID(doc, pos) {
  const node = doc.nodeAt(pos)
  if (!carriesBlockID(node)) return false
  const $pos = doc.resolve(pos)
  for (let depth = $pos.depth; depth > 0; depth -= 1) {
    if (/table/i.test($pos.node(depth).type.name)) return false
  }
  return true
}

/// The id a parsed paragraph or heading ends with, taken off its last words.
function takeMarkerFromMarkdownNode(node) {
  const children = Array.isArray(node?.children) ? node.children : null
  const last = children?.at(-1)
  if (!last || last.type !== 'text') return ''
  const taken = takeBlockIDMarker(last.value)
  if (!taken) return ''
  if (taken.text) last.value = taken.text
  else children.pop()
  return taken.blockID
}

function withBlockIDOnDOM(spec, blockID) {
  if (!blockID || !Array.isArray(spec)) return spec
  const [tag, second, ...rest] = spec
  const isAttrs = second && typeof second === 'object' && !Array.isArray(second) && !(second instanceof Node)
  return isAttrs
    ? [tag, { ...second, 'data-block-id': blockID }, ...rest]
    : [tag, { 'data-block-id': blockID }, ...spec.slice(1)]
}

/// Give paragraphs and headings their id: read off the Markdown, kept as an
/// attribute, written back last. Milkdown's own runners do the rest, so a
/// block with no id reads and writes exactly as it did.
function withBlockIDs(ctx) {
  for (const schemaSlice of [paragraphSchema, headingSchema]) {
    ctx.update(schemaSlice.key, (base) => (schemaCtx) => {
      const schema = base(schemaCtx)
      const parseRunner = schema.parseMarkdown.runner
      const serializeRunner = schema.toMarkdown.runner
      return {
        ...schema,
        attrs: { ...(schema.attrs ?? {}), blockID: { default: '', validate: 'string' } },
        parseDOM: (schema.parseDOM ?? []).map((rule) => ({
          ...rule,
          getAttrs: (dom) => {
            const attrs = typeof rule.getAttrs === 'function' ? rule.getAttrs(dom) : (rule.attrs ?? null)
            if (attrs === false) return false
            const blockID = dom instanceof HTMLElement ? String(dom.dataset.blockId ?? '') : ''
            return { ...(attrs ?? {}), blockID: isBlockID(blockID) ? blockID : '' }
          },
        })),
        toDOM: (node) => withBlockIDOnDOM(schema.toDOM(node), node.attrs.blockID),
        parseMarkdown: {
          match: schema.parseMarkdown.match,
          runner: (state, node, type) => {
            const blockID = takeMarkerFromMarkdownNode(node)
            parseRunner(state, node, type)
            if (!blockID) return
            const parent = state.top()
            const content = parent?.content
            const built = content?.at(-1)
            if (built?.type === type) content[content.length - 1] = type.create({ ...built.attrs, blockID }, built.content, built.marks)
          },
        },
        toMarkdown: {
          match: schema.toMarkdown.match,
          runner: (state, node) => {
            serializeRunner(state, node)
            const blockID = node.attrs.blockID
            if (!blockID) return
            const written = state.top()?.children?.at(-1)
            if (!written || (written.type !== 'paragraph' && written.type !== 'heading')) return
            // Raw, so the serializer escapes nothing in it; after the words,
            // or alone when the block has none.
            const children = (written.children ?? []).filter((child) => (
              !(child.type === 'html' && /^<br\s*\/?>$/i.test(String(child.value ?? '').trim()))
            ))
            // One space before the marker, as `DocGraphSyntax.appendingBlockID`
            // writes it: the words' own trailing whitespace is not kept.
            const last = children.at(-1)
            if (last?.type === 'text' && /[ \t]+$/.test(last.value ?? '')) {
              last.value = last.value.replace(/[ \t]+$/, '')
              if (!last.value) children.pop()
            }
            children.push({ type: 'html', value: `${children.length ? ' ' : ''}^${blockID}` })
            written.children = children
          },
        },
      }
    })
  }
}

// ─── An id stays with its block, once ───────────────────────────────────────

const blockIDPluginKey = new PluginKey('foreverlm-block-ids')
/// Set while a paste or a drop is being handled, so the transaction it makes
/// is known for one (Milkdown's paste dispatches without saying so).
let pastingNow = false
let droppingNow = null
/// Ids cut from this doc: a block cut and pasted back is moved, and keeps
/// its id, so what referenced it still does.
const cutBlockIDs = new Set()
/// The blocks the paste or drop being handled brings, `[{ blockID, words }]`.
let pastedBlocks = []
const blockIDPositionCache = new WeakMap()

function blockIDPositions(doc) {
  if (blockIDPositionCache.has(doc)) return blockIDPositionCache.get(doc)
  const positions = new Map()
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true
    const blockID = node.attrs?.blockID
    if (blockID) {
      if (!positions.has(blockID)) positions.set(blockID, [])
      positions.get(blockID).push(pos)
    }
    return false
  })
  blockIDPositionCache.set(doc, positions)
  return positions
}

document.addEventListener('paste', () => {
  pastingNow = true
  setTimeout(() => { pastingNow = false }, 0)
}, true)

document.addEventListener('drop', (event) => {
  const view = activeEditorView()
  // A drag inside the page that moves (no ⌥) takes its blocks along: they
  // keep their ids. Anything else dropped is a copy.
  droppingNow = { move: Boolean(view?.dragging?.move) && !event.altKey }
  setTimeout(() => { droppingNow = null }, 0)
}, true)

document.addEventListener('cut', () => {
  const view = activeEditorView()
  if (!view) return
  const { from, to } = view.state.selection
  view.state.doc.nodesBetween(from, to, (node) => {
    if (node.isTextblock && node.attrs?.blockID) cutBlockIDs.add(node.attrs.blockID)
    return !node.isTextblock
  })
}, true)

/// An id belongs to its block's words, the way Roam's uid belongs to its
/// block: it follows the words through every edit and stands once. After any
/// change to the doc:
///
/// - A paste, or a dropped copy, brings no ids in (two blocks would answer to
///   one reference), except a block cut from this doc, which is being moved.
/// - A block whose words are still there keeps its id on the block that holds
///   them: a paragraph turned into a heading, a block joined onto one with no
///   id of its own. Words typed over a whole block are still that block.
/// - A block whose words all went together with its end (a selection from its
///   start into the next block, deleted) is gone, even though ProseMirror
///   keeps its node to hold the next block's words: its id goes, and the node
///   takes the id of the words it now holds.
/// - Two blocks with one id (a split): the half the block began as keeps it;
///   a split at the very start leaves the words in the second half, and the
///   words keep it.
function normalizedBlockIDs(transactions, oldState, newState) {
  const before = blockIDPositions(oldState.doc)
  const after = blockIDPositions(newState.doc)
  const moving = pastingNow || droppingNow?.move
  if (before.size === 0 && after.size === 0 && !moving) return null
  const mapping = new Mapping()
  for (const step of transactions) mapping.appendMapping(step.mapping)
  const tr = newState.tr
  let changed = false
  const setID = (pos, blockID) => {
    const node = tr.doc.nodeAt(pos)
    if (!node || !carriesBlockID(node) || node.attrs.blockID === blockID) return
    tr.setNodeMarkup(pos, null, { ...node.attrs, blockID })
    changed = true
  }
  const textblockAt = (pos) => {
    const $pos = tr.doc.resolve(Math.max(0, Math.min(pos, tr.doc.content.size)))
    return $pos.depth > 0 && $pos.parent.isTextblock ? { node: $pos.parent, pos: $pos.before() } : null
  }
  const standsIn = (doc, blockID) => {
    let found = false
    doc.descendants((node) => {
      if (found) return false
      if (node.isTextblock) {
        found = node.attrs?.blockID === blockID
        return false
      }
      return true
    })
    return found
  }

  const copying = pastingNow || (droppingNow && !droppingNow.move)
  if (copying) {
    for (const [blockID, positions] of after) {
      if (before.has(blockID) || cutBlockIDs.has(blockID)) continue
      for (const pos of positions) setID(pos, '')
    }
  }

  for (const [blockID, positions] of before) {
    for (const pos of positions) {
      const node = oldState.doc.nodeAt(pos)
      if (!node) continue
      const start = mapping.mapResult(pos + 1, 1)
      const end = mapping.mapResult(pos + node.nodeSize - 1, -1)
      // `deletedAfter`: what followed the block's last word, its end, went.
      // Words typed over the whole block replace up to its end, not past it.
      const endWent = end.deletedAfter
      if (node.content.size > 0 && end.pos > start.pos) {
        const holder = textblockAt(end.pos)
        if (holder && !holder.node.attrs.blockID && carriesBlockID(holder.node) && !standsIn(tr.doc, blockID)) {
          setID(holder.pos, blockID)
        }
      } else if (endWent && node.content.size > 0) {
        const holder = textblockAt(start.pos)
        if (holder?.node.attrs.blockID === blockID) {
          // The words it holds now: whose were they?
          let successor = ''
          for (const [otherID, otherPositions] of before) {
            if (otherID === blockID) continue
            for (const otherPos of otherPositions) {
              const other = oldState.doc.nodeAt(otherPos)
              if (!other || other.content.size === 0) continue
              const otherEnd = mapping.mapResult(otherPos + other.nodeSize - 1, -1)
              if (!otherEnd.deleted && otherEnd.pos > holder.pos && otherEnd.pos < holder.pos + holder.node.nodeSize) successor = otherID
            }
          }
          setID(holder.pos, successor && !standsIn(tr.doc, successor) ? successor : '')
        }
      } else {
        // Emptied, or retyped, and still standing: it keeps its id.
        const own = mapping.mapResult(pos, 1)
        const holder = own.deleted ? null : textblockAt(own.pos + 1)
        if (holder && !holder.node.attrs.blockID && carriesBlockID(holder.node) && !standsIn(tr.doc, blockID)) {
          setID(holder.pos, blockID)
        }
      }
    }
  }

  // A block moved, by a paste of what was cut here or by a drag: ProseMirror
  // often pours the moved words into the block at the caret rather than
  // placing the moved block itself, so its id is found again by its words.
  if (moving) {
    const carried = pastedBlocks.filter(({ blockID }) => droppingNow?.move || cutBlockIDs.has(blockID))
    const near = tr.selection.from
    for (const { blockID, words } of carried) {
      if (!words.trim() || standsIn(tr.doc, blockID)) continue
      let best = null
      tr.doc.descendants((node, pos) => {
        if (!node.isTextblock) return true
        if (!node.attrs?.blockID && canTakeBlockID(tr.doc, pos) && node.textContent.includes(words)) {
          const exact = node.textContent === words
          const distance = Math.abs(pos - near)
          if (!best || (exact && !best.exact) || (exact === best.exact && distance < best.distance)) best = { pos, exact, distance }
        }
        return false
      })
      if (best) setID(best.pos, blockID)
    }
  }

  for (const [blockID, positions] of blockIDPositions(tr.doc)) {
    if (positions.length < 2) continue
    const old = before.get(blockID) ?? []
    const mapped = new Set(old.map((pos) => mapping.mapResult(pos, 1)).filter((result) => !result.deleted).map((result) => result.pos))
    let keeper = positions.find((pos) => mapped.has(pos)) ?? positions[0]
    if (!tr.doc.nodeAt(keeper)?.textContent.trim()) {
      keeper = positions.find((pos) => pos !== keeper && tr.doc.nodeAt(pos)?.textContent.trim()) ?? keeper
    }
    for (const pos of positions) if (pos !== keeper) setID(pos, '')
  }
  return changed ? tr : null
}

const blockIDPlugin = $prose(() => new Plugin({
  key: blockIDPluginKey,
  appendTransaction(transactions, oldState, newState) {
    if (applyingExternalMarkdown || !transactions.some((tr) => tr.docChanged)) return null
    // A block moved by its handle takes its ids along untouched.
    if (transactions.some((tr) => tr.getMeta('foreverlm-block-move'))) return null
    return normalizedBlockIDs(transactions, oldState, newState)
  },
  props: {
    // The blocks a paste or a drop brings, read before ProseMirror fits them
    // into the doc: fitting rebuilds an open slice's first block from the
    // block at the caret, which drops what the moved block carried.
    transformPasted(slice) {
      const carried = []
      slice.content.descendants((node) => {
        if (!node.isTextblock) return true
        if (node.attrs?.blockID) carried.push({ blockID: node.attrs.blockID, words: node.textContent })
        return false
      })
      pastedBlocks = carried
      setTimeout(() => { pastedBlocks = [] }, 0)
      return slice
    },
  },
}))

/// Give a block of this doc an id, or read the one it has. An ordinary edit
/// of this doc, saved like any other; null when the block cannot take one.
function ensureBlockID(view, pos) {
  const node = view.state.doc.nodeAt(pos)
  if (!node || !canTakeBlockID(view.state.doc, pos)) return null
  if (node.attrs.blockID) return node.attrs.blockID
  if (!isEditable) return null
  const blockID = newBlockID()
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(view.state.tr.setNodeMarkup(pos, null, { ...node.attrs, blockID }))
  return blockID
}

// ─── Lines pasted from a PDF ────────────────────────────────────────────────
// Text copied from a PDF arrives one printed line at a time: PDFKit (the
// Reader, Preview) writes every line as a paragraph of its own, and a
// plain-text copy breaks one paragraph at every line. Which breaks the page's
// width made and which the author made only a reader can tell, so the host
// asks the Pasted Line Joining model (PastedLineJoining.swift) what each break
// was, and the editor joins the lines itself (pasted-lines.js), as an undo step
// of its own, while the paste is still as it came. No word of the paste is the
// model's.

const pastedLinesKey = new PluginKey('foreverlm-pasted-lines')
/// Whether the host answers `pastedLinesNeedJoining` (`setJoinsPastedLines`).
let joinsPastedLines = false
/// The lines each question carried, by request id, to be found again unchanged.
const askedLines = new Map()
let pastedLinesRequestCount = 0

// ─── A pasted block starts its own line ─────────────────────────────────────
// ProseMirror pours the first block of a paste into the paragraph at the
// caret. For a paragraph that is what typing would do; for a heading, a list,
// a quote or code it is not: pasted at the end of a written sentence, the
// heading "Results from the trial" became "Start here.Results from the trial"
// with its heading gone. At either end of a line with words in it, such a
// paste now starts on a line of its own; in the middle of a line, and for
// plain paragraphs anywhere, a paste continues the line as before.

/// The first block a paste writes, read the way the paste will read it:
/// ProseMirror's slice when the clipboard has HTML, the page's Markdown reader
/// when it has only text (Milkdown's paste reads text as Markdown).
function firstPastedBlock(event, slice) {
  const data = event.clipboardData
  if (!data) return null
  if (data.getData('text/html')) return slice?.content?.firstChild ?? null
  const text = data.getData('text/plain')
  if (!text || !editor) return null
  try {
    const parse = editor.editor.action((ctx) => ctx.get(parserCtx))
    const doc = parse(text)
    return doc && typeof doc !== 'string' ? doc.firstChild : null
  } catch {
    return null
  }
}

/// Tab in a paragraph or a heading does nothing. Crepe's indent plugin typed
/// four spaces there (over a selection too, after it), which Markdown cannot
/// keep as an indent: the page stored "&#x20;   " and a published page drew
/// none. Left to the browser, Tab would take the caret out of the page. A list
/// item, a table cell and code keep their own Tab.
function withQuietTab(ctx) {
  ctx.update(editorViewOptionsCtx, (previous) => ({
    ...previous,
    handleKeyDown: (view, event) => {
      if (event.key === 'Tab' && !event.metaKey && !event.ctrlKey && !event.altKey && !tabActsHere(view.state)) {
        event.preventDefault()
        return true
      }
      return previous.handleKeyDown?.(view, event) ?? false
    },
  }))
}

/// Backspace at the start of a heading, a quote or a list item takes the
/// block's kind away first, as writing apps do: the heading becomes a
/// paragraph, the quote's line leaves the quote, the item leaves its list one
/// level at a time. ProseMirror's own Backspace poured the line into the block
/// above ("Intro.quoted line", or a quote into the page's title), and
/// Milkdown's step for a heading made a level-2 heading a level-1 one. A
/// note's lines keep the footnotes' own handling.
function withBackspaceUnwrapping(ctx) {
  ctx.update(editorViewOptionsCtx, (previous) => ({
    ...previous,
    handleKeyDown: (view, event) => {
      if (event.key === 'Backspace' && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey
        && unwrapAtStart(view.state, view.dispatch)) {
        event.preventDefault()
        return true
      }
      return previous.handleKeyDown?.(view, event) ?? false
    },
  }))
}

function unwrapAtStart(state, dispatch) {
  const { $from, empty } = state.selection
  if (!empty || $from.parentOffset !== 0 || !$from.parent.isTextblock || $from.depth < 1) return false
  const line = $from.parent
  const { schema } = state
  if (line.type.name === 'heading') {
    const attrs = 'blockID' in (schema.nodes.paragraph.spec.attrs ?? {}) ? { blockID: line.attrs.blockID ?? '' } : null
    return setBlockType(schema.nodes.paragraph, attrs)(state, dispatch)
  }
  if ($from.depth < 2 || $from.index($from.depth - 1) !== 0) return false
  const holder = $from.node($from.depth - 1)
  if (holder.type.name === 'list_item') return liftListItem(holder.type)(state, dispatch)
  if (holder.type.name === 'blockquote') return lift(state, dispatch)
  return false
}

/// `[ ] ` (or `[] `, `[x] `) at the start of a line makes a checklist item,
/// as the slash menu's Checklist row says. GFM's own rule only turns an item
/// already in a list into a task, so typed on a plain line the brackets stayed
/// as text.
/// One of Milkdown's own rules (`inputRulesCtx`), because the dollar-math
/// change rebuilds the input rules plugin from that list.
const checklistShortcut = $inputRule((ctx) => wrappingInputRule(
  /^\[( |x|X)?\]\s$/,
  listItemSchema.type(ctx),
  (match) => ({ checked: (match[1] ?? '').toLowerCase() === 'x' }),
))

/// Return on a line that is only a code fence or the math one makes the block
/// it names, as in a Markdown editor: "```" (with a language, "```swift")
/// makes code and "$$" an equation. Milkdown's rules wait for a space after
/// the fence, which nobody types, so Return left the backticks as text.
function withBlockShortcutsOnEnter(ctx) {
  ctx.update(editorViewOptionsCtx, (previous) => ({
    ...previous,
    handleKeyDown: (view, event) => {
      if (event.key === 'Enter' && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && !event.isComposing
        && blockFromFence(view.state, view.dispatch)) {
        event.preventDefault()
        return true
      }
      return previous.handleKeyDown?.(view, event) ?? false
    },
  }))
}

function blockFromFence(state, dispatch) {
  const { $from, empty } = state.selection
  if (!empty || $from.parent.type.name !== 'paragraph' || $from.parentOffset !== $from.parent.content.size) return false
  const text = $from.parent.textContent
  const code = /^```([\w+#.-]*)$/.exec(text)
  const language = code ? code[1] : text === '$$' ? 'LaTeX' : null
  if (language == null) return false
  const codeBlock = state.schema.nodes.code_block
  const start = $from.start()
  const tr = state.tr.delete(start, $from.end())
  tr.setBlockType(start, start, codeBlock, { language })
  tr.setSelection(TextSelection.create(tr.doc, start))
  dispatch(tr.scrollIntoView())
  return true
}

function tabActsHere(state) {
  const { $from, $to } = state.selection
  for (const $pos of [$from, $to]) {
    if ($pos.parent.type.spec.code) return true
    for (let depth = $pos.depth; depth > 0; depth -= 1) {
      if (['list_item', 'table_cell', 'table_header'].includes($pos.node(depth).type.name)) return true
    }
  }
  return false
}

function withBlockPastesOnTheirOwnLine(ctx) {
  ctx.update(editorViewOptionsCtx, (previous) => ({
    ...previous,
    // A view prop runs before every plugin's, Milkdown's paste among them:
    // this only makes room, and the paste then lands in it.
    handlePaste: (view, event, slice) => {
      const pictures = pictureFiles(event.clipboardData)
      if (pictures.length) {
        keepPictures(pictures)
        return true
      }
      if (linkSelectionToPastedAddress(view, event)) return true
      if (pastePlainWords(view, event) || pastePhraseWithItsSpaces(view, event, slice)) return true
      makeRoomForPastedBlock(view, event, slice)
      return previous.handlePaste?.(view, event, slice) ?? false
    },
    handleDrop: (view, event, slice, moved) => {
      const pictures = moved ? [] : pictureFiles(event.dataTransfer)
      if (pictures.length) {
        // Where it was dropped is where the pictures go in.
        const at = view.posAtCoords({ left: event.clientX, top: event.clientY })
        if (at) view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(at.pos))))
        keepPictures(pictures)
        event.preventDefault()
        return true
      }
      return previous.handleDrop?.(view, event, slice, moved) ?? false
    },
  }))
}

/// Pictures pasted or dropped onto a page (a screenshot, an image copied from
/// Preview or Finder) are kept with the page, as a file picked from the Image
/// row is: the host stores each in the page's attachments and writes it at the
/// caret (`imagesPasted`, answered with `insertAttachment`). Left to Milkdown,
/// a picture became a `blob:` address that died with the page, so a pasted
/// figure was gone the next time the page opened. Only a host that keeps
/// pictures (`setSlashFeatures({ images })`) is sent them; words copied with
/// a picture are a passage, and paste as one.
function pictureFiles(data) {
  if (!slashFeatures.images || !data) return []
  const files = [...(data.files ?? [])].filter((file) => file.type.startsWith('image/'))
  if (files.length === 0) return []
  const html = data.getData?.('text/html') ?? ''
  const words = html.replace(/<img\b[^>]*>/gi, '').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim()
  return words ? [] : files
}

function keepPictures(files) {
  Promise.all(files.map((file) => new Promise((resolve) => {
    const reader = new FileReader()
    reader.onload = () => resolve({ name: file.name || '', type: file.type, dataURL: String(reader.result ?? '') })
    reader.onerror = () => resolve(null)
    reader.readAsDataURL(file)
  }))).then((images) => {
    const read = images.filter((image) => image?.dataURL.startsWith('data:image/'))
    if (read.length) post('imagesPasted', { images: read })
  })
}

/// A web address pasted over selected words links them, as ChatGPT's, Notion's
/// and Google's pages do, rather than putting the address in their place.
/// Words that stand on sources are left to the ordinary paste: a passage's
/// sources are a link over its words, and a second link would replace them.
function linkSelectionToPastedAddress(view, event) {
  const address = (event.clipboardData?.getData('text/plain') ?? '').trim()
  if (!/^https?:\/\/\S+$/i.test(address)) return false
  try {
    new URL(address)
  } catch {
    return false
  }
  const { from, to, empty, $from, $to } = view.state.selection
  if (empty || !$from.sameParent($to) || !$from.parent.isTextblock || $from.parent.type.spec.code) return false
  if (rangeHasGrounding(view.state, from, to)) return false
  const link = view.state.schema.marks.link
  view.dispatch(view.state.tr.addMark(from, to, link.create({ href: address })))
  return true
}

/// One line copied as plain text goes into the line at the caret with the
/// spaces at its ends. Read as Markdown it lost them: " and more words"
/// pasted after "Start here." gave "Start here.and more words". Its words are
/// still read as Markdown, so " with **bold**" pastes bold.
function pastePlainWords(view, event) {
  const data = event.clipboardData
  if (!data || data.getData('text/html') || !editor) return false
  const text = data.getData('text/plain')
  if (!text || !text.trim() || /[\r\n]/.test(text)) return false
  const { $from } = view.state.selection
  if (!$from.parent.isTextblock || $from.parent.type.spec.code) return false
  let words
  try {
    const parse = editor.editor.action((ctx) => ctx.get(parserCtx))
    const doc = parse(text)
    words = doc && typeof doc !== 'string' && doc.childCount === 1 ? doc.firstChild : null
  } catch {
    return false
  }
  if (!words || words.type.name !== 'paragraph' || words.content.size === 0) return false
  // Plain words take the formatting at the caret, as typed words do.
  if (words.childCount === 1 && words.firstChild.isText && words.firstChild.marks.length === 0 && words.textContent === text.trim()) {
    view.dispatch(view.state.tr.insertText(text).scrollIntoView())
    return true
  }
  const { schema } = view.state
  const leading = /^\s*/.exec(text)[0]
  const trailing = /\s*$/.exec(text)[0]
  let inline = words.content
  if (leading) inline = Fragment.from(schema.text(leading)).append(inline)
  if (trailing) inline = inline.append(Fragment.from(schema.text(trailing)))
  view.dispatch(view.state.tr.replaceSelection(new Slice(inline, 0, 0)).scrollIntoView())
  return true
}

/// A phrase copied from a web page keeps the spaces at its ends. The HTML
/// reader drops them ("Start here.and the words"); the plain text the browser
/// puts beside the HTML says what they were.
function pastePhraseWithItsSpaces(view, event, slice) {
  const data = event.clipboardData
  const text = data?.getData('text/plain') ?? ''
  if (!data?.getData('text/html') || !text.trim() || /[\r\n]/.test(text) || !slice) return false
  if (view.state.selection.$from.parent.type.spec.code) return false
  let inline = slice.content
  // A phrase reads either as bare inline nodes or as one open paragraph.
  if (inline.childCount === 1 && inline.firstChild.type.name === 'paragraph' && slice.openStart > 0) {
    inline = inline.firstChild.content
  }
  let phrase = inline.size > 0
  inline.forEach((node) => { if (!node.isInline) phrase = false })
  if (!phrase) return false
  const words = inline.textBetween(0, inline.size, '', '')
  const leading = /^\s/.test(words) ? '' : /^\s*/.exec(text)[0]
  const trailing = /\s$/.test(words) ? '' : /\s*$/.exec(text)[0]
  if (!leading && !trailing) return false
  const { schema } = view.state
  if (leading) inline = Fragment.from(schema.text(leading)).append(inline)
  if (trailing) inline = inline.append(Fragment.from(schema.text(trailing)))
  view.dispatch(view.state.tr.replaceSelection(new Slice(inline, 0, 0)).scrollIntoView())
  return true
}

function makeRoomForPastedBlock(view, event, slice) {
  const { selection } = view.state
  if (!selection.empty || !view.editable) return
  const { $from } = selection
  const line = $from.parent
  if (!line.isTextblock || line.type.spec.code || line.content.size === 0) return
  const atEnd = $from.parentOffset === line.content.size
  const atStart = $from.parentOffset === 0
  if (!atEnd && !atStart) return
  // Words with no block around them (a phrase copied from a page) continue
  // the line like a paragraph does.
  const first = firstPastedBlock(event, slice)
  if (!first || !first.isBlock || first.type.name === 'paragraph') return
  const tr = view.state.tr.split($from.pos)
  // At the start, the empty line the split leaves is the one before the words.
  if (atStart) tr.setSelection(TextSelection.create(tr.doc, $from.pos))
  view.dispatch(tr)
}

function setJoinsPastedLines(joins) {
  joinsPastedLines = Boolean(joins)
}

/// What the paste being handled wrote (`pasted`), and the spans of the
/// pastes the host was asked about (`asked`), mapped through every change.
const pastedLinesPlugin = $prose(() => new Plugin({
  key: pastedLinesKey,
  state: {
    init: () => ({ pasted: null, asked: new Map() }),
    apply(tr, value) {
      let { pasted, asked } = value
      if (tr.docChanged) {
        if (pasted) pasted = { from: tr.mapping.map(pasted.from, -1), to: tr.mapping.map(pasted.to, 1) }
        if (asked.size) {
          asked = new Map([...asked].map(([id, span]) => [id, {
            from: tr.mapping.map(span.from, 1),
            to: tr.mapping.map(span.to, -1),
          }]))
        }
        // Milkdown's paste dispatches without saying so; `pastingNow` does.
        if (pastingNow && joinsPastedLines && !tr.getMeta('appendedTransaction')) {
          const written = writtenSpan(tr)
          if (written) {
            pasted = pasted
              ? { from: Math.min(pasted.from, written.from), to: Math.max(pasted.to, written.to) }
              : written
          }
        }
      }
      const meta = tr.getMeta(pastedLinesKey)
      if (meta) {
        pasted = null
        asked = new Map(asked)
        if (meta.ask) asked.set(meta.ask.id, meta.ask.span)
        if (meta.done) asked.delete(meta.done)
      }
      return pasted === value.pasted && asked === value.asked ? value : { pasted, asked }
    },
  },
}))

/// Once the paste is in: ask the host about its lines, or forget it.
function askAboutPaste() {
  const view = activeEditorView()
  const pasted = view ? pastedLinesKey.getState(view.state)?.pasted : null
  if (!pasted) return
  const passage = isEditable ? pastedLines(view.state.doc, pasted.from, pasted.to) : null
  const asking = passage && mayBePrintedLines(passage.lines)
  const requestID = asking ? `paste-${Date.now()}-${(pastedLinesRequestCount += 1)}` : null
  view.dispatch(view.state.tr
    .setMeta(pastedLinesKey, asking ? { ask: { id: requestID, span: { from: passage.from, to: passage.to } } } : {})
    .setMeta('addToHistory', false))
  if (!asking) return
  askedLines.set(requestID, passage.lines)
  post('pastedLinesNeedJoining', { requestID, lines: passage.lines })
}

document.addEventListener('paste', () => {
  if (joinsPastedLines) setTimeout(askAboutPaste, 0)
}, true)

/// The host's answer: what each break of a paste was, in order.
function completePastedLineJoining(requestID, breaks) {
  const lines = askedLines.get(requestID)
  askedLines.delete(requestID)
  const view = activeEditorView()
  if (!view) return
  const span = pastedLinesKey.getState(view.state)?.asked.get(requestID)
  let tr = view.state.tr
  if (lines && span && isEditable) {
    try {
      joinPastedLines(tr, span, lines, breaks)
    } catch (error) {
      console.warn('Pasted lines left as pasted', error)
      tr = view.state.tr
    }
  }
  tr.setMeta(pastedLinesKey, { done: requestID })
  if (tr.docChanged) {
    // Its own undo step: ⌘Z after it gives back the lines as they were pasted.
    closeHistory(tr)
    userHasInteracted = true
    hasUserChanges = true
  } else {
    tr.setMeta('addToHistory', false)
  }
  view.dispatch(tr)
}

/// No answer is coming for this paste: it stays as pasted.
function forgetPastedLineJoining(requestID) {
  askedLines.delete(requestID)
  const view = activeEditorView()
  if (!view || !pastedLinesKey.getState(view.state)?.asked.has(requestID)) return
  view.dispatch(view.state.tr.setMeta(pastedLinesKey, { done: requestID }).setMeta('addToHistory', false))
}

// ─── Drawing the grammar ────────────────────────────────────────────────────
// `((id))` reads as the referenced block's words, `{{embed: ((id))}}` as the
// block framed, `[[Title]]` and `#tag` as links to pages. The block the caret
// is in shows what was typed, as Roam does, so a reference can be edited; a
// page that is not focused, read-only, or being published shows every
// reference drawn.

const graphPluginKey = new PluginKey('foreverlm-notes-graph')

/// The text blocks being written in: the ones the selection's ends are in.
function editingTextblocks(state) {
  if (drawingEveryReference || !isEditable || !editorFocused) return null
  const { $from, $to } = state.selection
  const editing = new Set()
  if ($from.parent.isTextblock && $from.depth > 0) editing.add($from.before())
  if ($to.parent.isTextblock && $to.depth > 0) editing.add($to.before())
  return editing
}

function editingKey(state) {
  const editing = editingTextblocks(state)
  return editing ? [...editing].sort((a, b) => a - b).join(',') : ''
}

/// A text block's words as one string the grammar is read from: code and
/// links (other than grounding) stand as placeholders, so nothing inside them
/// is grammar, and every other inline node keeps its width, so an offset in
/// the string is an offset from the block's first position.
function graphText(node) {
  let text = ''
  node.forEach((child) => {
    if (child.isText) {
      const excluded = child.marks.some((mark) => mark.type.name === 'inlineCode'
        || (mark.type.name === 'link' && groundingSourceIDs(mark.attrs?.href ?? '').length === 0))
      text += excluded ? '\uFFFC'.repeat(child.text.length) : child.text
    } else {
      text += '\uFFFC'.repeat(child.nodeSize)
    }
  })
  return text
}

function graphDecorations(state) {
  if (!graph.active) return DecorationSet.empty
  const decorations = []
  const unknown = new Set()
  const editing = editingTextblocks(state)
  const live = new Map()
  state.doc.descendants((node, pos) => {
    if (!node.isTextblock) return true
    if (node.attrs?.blockID && !live.has(node.attrs.blockID)) live.set(node.attrs.blockID, { node, pos })
    return false
  })
  const widget = (pos, render, key) => Decoration.widget(pos, render, {
    side: -1,
    key,
    ignoreSelection: true,
    stopEvent: () => true,
  })
  state.doc.descendants((node, pos) => {
    if (!node.isTextblock) return true
    if (node.type.spec.code) return false
    const from = pos + 1
    const to = pos + node.nodeSize - 1
    const writing = editing?.has(pos) ?? false
    const blockID = node.attrs?.blockID
    const count = blockID ? graph.refCounts.get(blockID) ?? 0 : 0
    if (count > 0) decorations.push(widget(from, () => referenceCountPill(blockID, count), `count:${blockID}:${count}`))
    if (node.childCount === 0) return false
    const text = graphText(node)
    if (node.type.name === 'paragraph') {
      const embedded = embeddedBlockID(text)
      if (embedded) {
        const block = resolvedBlock(embedded, live)
        if (block === undefined) unknown.add(embedded)
        if (writing || block === undefined) {
          decorations.push(Decoration.inline(from, to, { class: 'artifact-graph-source' }))
          if (block === undefined) decorations.push(Decoration.node(pos, pos + node.nodeSize, { class: 'artifact-embed-unresolved' }))
          return false
        }
        decorations.push(Decoration.node(pos, pos + node.nodeSize, { class: 'artifact-embed-paragraph' }))
        decorations.push(Decoration.inline(from, to, { class: 'artifact-graph-hidden' }))
        const html = block ? renderedSnippet('embed', embedded, block, () => embedBodyHTML(block)) : ''
        decorations.push(widget(from, () => embedFrame(embedded, block, html), `embed:${embedded}:${blockSignature(block)}:${hashString(html)}`))
        return false
      }
    }
    for (const token of graphTokens(text)) {
      const start = from + token.start
      const end = from + token.end
      if (token.type === 'ref') {
        const block = resolvedBlock(token.blockID, live)
        if (block === undefined) unknown.add(token.blockID)
        if (writing || block === undefined) {
          decorations.push(Decoration.inline(start, end, { class: 'artifact-graph-source' }))
          continue
        }
        decorations.push(Decoration.inline(start, end, { class: 'artifact-graph-hidden' }))
        const html = block ? renderedSnippet('ref', token.blockID, block, () => renderInline(block.markdown, graphSnippetOptions(), 1)) : ''
        decorations.push(widget(end, () => referenceSpan(token.blockID, block, html), `ref:${token.blockID}:${blockSignature(block)}:${hashString(html)}`))
        continue
      }
      const exists = pageExists(token.title)
      decorations.push(Decoration.inline(start, end, {
        class: `artifact-page-link${token.type === 'tag' ? ' is-tag' : ''}${exists === false ? ' is-new' : ''}`,
        'data-page-title': token.title,
      }))
      const opening = token.type === 'page' ? [start, start + 2] : token.bracketed ? [start + 1, start + 3] : null
      if (opening) {
        decorations.push(Decoration.inline(opening[0], opening[1], { class: 'artifact-page-bracket' }))
        decorations.push(Decoration.inline(end - 2, end, { class: 'artifact-page-bracket' }))
      }
    }
    return false
  })
  if (unknown.size) scheduleBlocksRequest(unknown)
  return DecorationSet.create(state.doc, decorations)
}

const notesGraphPlugin = $prose(() => new Plugin({
  key: graphPluginKey,
  state: {
    init: (_config, state) => ({ editing: editingKey(state), decorations: graphDecorations(state) }),
    apply(tr, value, _previous, state) {
      const editing = editingKey(state)
      if (tr.docChanged || tr.getMeta(graphPluginKey) || editing !== value.editing) {
        return { editing, decorations: graphDecorations(state) }
      }
      return value
    },
  },
  props: {
    decorations: (state) => graphPluginKey.getState(state)?.decorations ?? null,
  },
}))

function refreshGraphDecorations() {
  const view = activeEditorView()
  if (!view || !document.body.classList.contains('ready')) return
  view.dispatch(view.state.tr.setMeta(graphPluginKey, true))
}

/// What the graph knows changed: every reference, embed and title link is
/// drawn again, and so is the page foot.
function graphContextChanged() {
  graphGeneration += 1
  refreshGraphDecorations()
  refreshFoot()
}

/// Draw every reference for the duration of `body`, the one the caret is in
/// as well, and go back to drawing as before.
function withEveryReferenceDrawn(body) {
  drawingEveryReference = true
  refreshGraphDecorations()
  try {
    return body()
  } finally {
    drawingEveryReference = false
    refreshGraphDecorations()
  }
}

/// A reference drawn as the words it reads: the referenced block's text,
/// underlined in the reference colour; "((missing block))" when the graph has
/// no such block. A plain press puts the caret after it, which shows the
/// reference as typed; ⌘- or ⇧-press, or a press on a page read as a page,
/// opens the block where it is.
function referenceSpan(blockID, block, html) {
  const span = document.createElement('span')
  span.className = block ? 'artifact-block-ref' : 'artifact-block-ref is-missing'
  span.contentEditable = 'false'
  span.dataset.blockId = blockID
  if (block) span.innerHTML = html
  else span.textContent = '((missing block))'
  span.addEventListener('mouseenter', () => scheduleReferencePreview(span, blockID, block))
  span.addEventListener('mouseleave', () => scheduleReferencePreviewHide())
  span.addEventListener('mousedown', (event) => {
    event.preventDefault()
    if (event.button !== 0) return
    if (event.metaKey || event.shiftKey || !isEditable) {
      if (block) post('openBlockRequested', { blockID })
      return
    }
    placeCaretAtWidget(span, 'after')
  })
  return span
}

/// The caret at a widget: just after a reference, at the end of an embed's
/// paragraph.
function placeCaretAtWidget(element, where) {
  const view = activeEditorView()
  if (!view) return
  let pos
  try {
    pos = view.posAtDOM(element, 0)
  } catch {
    return
  }
  const $pos = view.state.doc.resolve(Math.max(0, Math.min(pos, view.state.doc.content.size)))
  const target = where === 'end' && $pos.parent.isTextblock ? $pos.end() : $pos.pos
  view.focus()
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, target)))
}

/// An embed: the block and what is nested under it, framed and read-only,
/// with its page's title small above it. The title opens the block where it
/// is; a press on the frame puts the caret in the embed's own line, which
/// shows it as typed.
/// What an embed's frame holds: the block's words, as the bullet it is when
/// it is one, and what is nested under it, lists folded past two levels.
function embedBodyHTML(block) {
  const options = graphSnippetOptions()
  const children = block.childrenMarkdown ? renderMarkdown(block.childrenMarkdown, { ...options, depth: 1, foldListsDeeperThan: 2 }) : ''
  const words = renderInline(block.markdown, options, 1)
  return block.kind === 'listItem'
    ? `<ul class="artifact-snippet-list"><li><div class="artifact-snippet-item">${words}</div>${children}</li></ul>`
    : `<p>${words}</p>${children}`
}

function embedFrame(blockID, block, html) {
  const frame = document.createElement('span')
  frame.className = block ? 'artifact-embed' : 'artifact-embed is-missing'
  frame.contentEditable = 'false'
  frame.dataset.blockId = blockID
  if (!block) {
    frame.textContent = '((missing block))'
  } else {
    const title = document.createElement('button')
    title.type = 'button'
    title.className = 'artifact-embed-title'
    title.textContent = block.docTitle || 'Untitled'
    title.title = 'Open the block where it is'
    title.addEventListener('mousedown', (event) => event.preventDefault())
    title.addEventListener('click', (event) => {
      event.preventDefault()
      post('openBlockRequested', { blockID })
    })
    const body = document.createElement('span')
    body.className = 'artifact-embed-body artifact-snippet'
    body.innerHTML = html
    frame.append(title, body)
  }
  frame.addEventListener('mousedown', (event) => {
    if (event.target instanceof Element && event.target.closest('.artifact-embed-title, a, summary')) return
    event.preventDefault()
    if (event.button !== 0 || !isEditable) return
    placeCaretAtWidget(frame, 'end')
  })
  frame.addEventListener('click', (event) => {
    if (event.target instanceof Element && event.target.closest('a')) followSnippetLink(event)
  })
  return frame
}

/// How many blocks reference this one, at its trailing edge; a press lists
/// them (`blockReferencesRequested`).
function referenceCountPill(blockID, count) {
  const pill = document.createElement('button')
  pill.type = 'button'
  pill.className = 'artifact-block-ref-count'
  pill.contentEditable = 'false'
  pill.textContent = String(count)
  pill.title = count === 1 ? 'Referenced once' : `Referenced ${count} times`
  pill.setAttribute('aria-label', pill.title)
  pill.dataset.notesPanelAnchor = 'true'
  pill.addEventListener('mousedown', (event) => event.preventDefault())
  pill.addEventListener('click', (event) => {
    event.preventDefault()
    toggleBlockReferences(pill, blockID)
  })
  return pill
}

// Following a title link: hovering shows Open page; ⌘- or ⇧-press opens it,
// and so does a plain press on a page read as a page.
let pageLinkHoverTimer = null

document.addEventListener('mousedown', (event) => {
  const link = event.target instanceof Element ? event.target.closest('.milkdown .editor [data-page-title]') : null
  if (!link || event.button !== 0) return
  if (!(event.metaKey || event.shiftKey || !isEditable)) return
  event.preventDefault()
  event.stopPropagation()
  hideInAppLinkTooltip(true)
  post('openTitleRequested', { title: link.dataset.pageTitle })
}, true)

document.addEventListener('mouseover', (event) => {
  const link = event.target instanceof Element ? event.target.closest('.milkdown .editor [data-page-title]') : null
  clearTimeout(pageLinkHoverTimer)
  if (!link) return
  pageLinkHoverTimer = setTimeout(() => {
    if (!link.isConnected) return
    showPageLinkTooltip(link.dataset.pageTitle, link.getBoundingClientRect())
  }, 220)
})

document.addEventListener('mouseout', (event) => {
  const link = event.target instanceof Element ? event.target.closest('.milkdown .editor [data-page-title]') : null
  if (!link) return
  const next = event.relatedTarget instanceof Element ? event.relatedTarget : null
  if (next?.closest('.milkdown .editor [data-page-title]')?.dataset.pageTitle === link.dataset.pageTitle) return
  clearTimeout(pageLinkHoverTimer)
  if (inAppLinkTooltip?.dataset.kind === 'page') setTimeout(() => hideInAppLinkTooltip(), 120)
})

// ─── The `((` list ──────────────────────────────────────────────────────────
// Typing `((` searches every block of the library's Docs, through the host:
// the query goes out a beat after the last keystroke, and only the answer to
// the latest question is shown. Choosing writes `((id))` over `((query`.

let blockSearchTimer = null
let blockSearchCounter = 0

function openBlockPicker(trigger, view) {
  const previous = linkPickerState?.source === 'block' && linkPickerState.from === trigger.from ? linkPickerState : null
  const queryChanged = !previous || previous.query !== trigger.query
  openLinkPicker({
    ...trigger,
    rows: previous?.rows ?? [],
    loading: queryChanged ? true : previous.loading,
    requestID: previous?.requestID ?? null,
    anchorRect: caretAnchor(view, trigger.from),
  })
  if (queryChanged) scheduleBlockSearch()
}

function scheduleBlockSearch() {
  clearTimeout(blockSearchTimer)
  blockSearchTimer = setTimeout(() => {
    blockSearchTimer = null
    const state = linkPickerState
    if (state?.source !== 'block') return
    blockSearchCounter += 1
    state.requestID = `blocks-${blockSearchCounter}`
    post('blockSearchRequested', { requestID: state.requestID, query: state.query })
  }, 120)
}

/// The host's answer to `blockSearchRequested`: `[Hit]`. An answer to any
/// question but the latest is dropped.
function setBlockSearchResults(requestID, hits) {
  const state = linkPickerState
  if (state?.source !== 'block' || String(requestID) !== state.requestID) return
  state.rows = (Array.isArray(hits) ? hits : [])
    .filter((hit) => hit?.block && hit.docID)
    .slice(0, 12)
    .map(blockRow)
  state.loading = false
  state.notice = ''
  state.index = 0
  renderLinkPicker()
}

/// The text block of this doc a search hit stands for: by its id, else by its
/// words (whitespace aside), else the first that begins with them. The hit was
/// read from the doc as last saved, so its words are what is compared.
function findTextblockForBlock(doc, block) {
  const collapse = (value) => String(value ?? '').replace(/\s+/g, ' ').trim()
  const wanted = collapse(block?.plainText)
  let byID = null
  let equal = null
  let starting = null
  doc.descendants((node, pos) => {
    if (byID) return false
    if (!node.isTextblock) return true
    if (!canTakeBlockID(doc, pos)) return false
    if (block?.blockID && node.attrs.blockID === block.blockID) byID = { node, pos }
    const text = collapse(node.textContent)
    if (wanted && !equal && text === wanted) equal = { node, pos }
    if (wanted && !starting && text.startsWith(wanted)) starting = { node, pos }
    return false
  })
  return byID ?? equal ?? starting
}

/// Write a chosen block's reference (or, from `{{embed: ((`, its embed) over
/// the typed trigger. A block with an id is referenced by it; a block of this
/// doc without one is given one here, in the same edit; a block of another
/// doc without one is given one too, and the host writes it into that doc
/// (`blockIDAssigned`). False, writing nothing, when the block of this doc the
/// search read is no longer here as it read it.
function writeBlockReference(hit, from, to, { embed = false } = {}) {
  const view = activeEditorView()
  if (!view || !hit?.block) return true
  const tr = view.state.tr
  let blockID = isBlockID(hit.block.blockID) ? hit.block.blockID : ''
  const inThisDoc = Boolean(graph.docID) && hit.docID === graph.docID
  let assignedElsewhere = false
  if (!blockID && inThisDoc) {
    const found = findTextblockForBlock(tr.doc, hit.block)
    if (!found) return false
    blockID = found.node.attrs.blockID || newBlockID()
    if (!found.node.attrs.blockID) tr.setNodeMarkup(found.pos, null, { ...found.node.attrs, blockID })
  } else if (!blockID) {
    blockID = newBlockID()
    assignedElsewhere = true
  }
  if (!inThisDoc) {
    // Read from the search's answer until the host's context names it.
    fetchedBlocks.set(blockID, normalizedBlock({ ...hit.block, blockID, docID: hit.docID, docTitle: hit.docTitle }, blockID))
    missingBlockIDs.delete(blockID)
    if (assignedElsewhere || !graph.blocks.has(blockID)) provisionalBlockIDs.add(blockID)
  }
  const { schema } = tr.doc.type
  if (!embed) {
    const words = blockReference(blockID)
    tr.insertText(words, from, to)
    tr.setSelection(TextSelection.create(tr.doc, from + words.length))
  } else {
    const $from = tr.doc.resolve(from)
    const textblock = $from.parent
    const blockStart = $from.before()
    const rest = `${textblock.textBetween(0, from - $from.start(), ' ', ' ')}${textblock.textBetween(to - $from.start(), textblock.content.size, ' ', ' ')}`
    const words = blockEmbed(blockID)
    if (!rest.trim() && textblock.type.name === 'paragraph') {
      // The trigger was the line: the line becomes the embed.
      tr.replaceWith($from.start(), $from.end(), schema.text(words))
      tr.setSelection(TextSelection.create(tr.doc, $from.start() + words.length))
    } else {
      // The line has words of its own: the embed takes a line after it, in
      // the list when the line is a bullet.
      tr.delete(from, to)
      const paragraph = schema.nodes.paragraph.create(null, schema.text(words))
      const $line = tr.doc.resolve(blockStart + 1)
      const item = $line.depth >= 2 && $line.node($line.depth - 1).type.name === 'list_item' && $line.index($line.depth - 1) === 0
        ? $line.depth - 1
        : null
      if (item != null) {
        const listItem = $line.node(item)
        const attrs = listItem.attrs.checked == null ? listItem.attrs : { ...listItem.attrs, checked: false }
        tr.insert($line.after(item), listItem.type.create(attrs, paragraph))
      } else {
        tr.insert($line.after(), paragraph)
      }
      tr.setSelection(TextSelection.create(tr.doc, Math.min(from, tr.doc.content.size)))
    }
  }
  tr.setStoredMarks([])
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  if (assignedElsewhere) {
    post('blockIDAssigned', {
      docID: hit.docID,
      key: String(hit.block.key ?? ''),
      revision: String(hit.revision ?? ''),
      plainText: String(hit.block.plainText ?? ''),
      blockID,
    })
  }
  graphContextChanged()
  requestAnimationFrame(publishSelection)
  return true
}

/// A page made from the slash menu is named like a new Doc until the writer
/// names it.
const untitledPageTitle = 'Untitled Page'

/// The `/query` taken out of the text, the caret where it was; null when the
/// editor is gone.
function removeSlashText(from, to) {
  const view = activeEditorView()
  if (!view) return null
  const size = view.state.doc.content.size
  const start = Math.max(0, Math.min(Number(from), size))
  const end = Math.max(start, Math.min(Number(to), size))
  if (end > start) view.dispatch(view.state.tr.delete(start, end))
  return view
}

/// A `/` row, written where the `/query` stood. The rows that open something
/// (the AI panel, the host's picture picker) take the typing out first, so
/// what they leave behind is the empty line they were chosen on.
function runSlashCommand(command, from, to) {
  if (!command) return
  if (command.offset != null) {
    writeDayLink(relativeDayKey(command.offset), from, to)
    return
  }
  switch (command.id) {
    case 'chat':
      if (removeSlashText(from, to)) post('promptRequested', { text: '' })
      return
    case 'find-sources':
      if (removeSlashText(from, to)) post('promptRequested', { text: 'Find sources relevant to this page.' })
      return
    case 'reference':
      writePlainText('((', from, to)
      return
    case 'embed':
      writePlainText('{{embed: ((', from, to)
      return
    case 'mention':
      writePlainText('@', from, to)
      return
    case 'link':
      // The `[[` is the gesture: its list opens on its own once it is written.
      writePlainText('[[', from, to)
      return
    case 'page': {
      // A page inside this one is a new page, linked from here on the line
      // where it was asked for; the host makes it and opens it.
      const docID = newPageID()
      writeInAppLink({ title: untitledPageTitle, href: `${markdownSchemePrefix}doc/${docID}` }, from, to, { replaceText: true })
      post('pageCreationRequested', { docID, title: untitledPageTitle, open: true })
      return
    }
    case 'generate':
      if (removeSlashText(from, to)) openAIGenerate()
      return
    case 'visualize':
      if (removeSlashText(from, to)) openAIGenerate({ visualize: true })
      return
    case 'instructions':
    case 'prompt':
    case 'highlight':
      insertCalloutBlock(command.id, from, to)
      return
    case 'draw':
      if (removeSlashText(from, to)) openAIGenerate({ image: true })
      return
    case 'image':
      if (removeSlashText(from, to)) post('imageRequested', {})
      return
    case 'file':
      if (removeSlashText(from, to)) post('fileRequested', {})
      return
    case 'footnote':
      insertFootnoteForSlash(from, to)
      return
    default:
      runBlockSlashCommand(command.id, from, to)
  }
}

/// The page's top line pill (Edit with AI, Image, Visualize, Insert +, as
/// Codex draws it) runs the `/` list's rows from outside the page. The caret is
/// where the typed `/` would have been, so a passage that is selected is not
/// replaced: the row works after it. Answers whether the row ran; a row the
/// host has not turned on (`setSlashFeatures`) does not, as in the list.
function runSlashRow(id) {
  const item = slashItems.find((row) => row.id === id)
  const view = activeEditorView()
  if (!item || !view || !isEditable || !slashItemAvailable(item)) return false
  const { selection, doc } = view.state
  if (!selection.empty) {
    view.dispatch(view.state.tr.setSelection(TextSelection.near(doc.resolve(selection.to), 1)))
  }
  const at = view.state.selection.from
  runSlashCommand(item, at, at)
  return true
}

/// Insert +: the `/` list, opened at the caret. A `/` goes where the caret is
/// when that is a fresh line or follows a space (where typing one would open
/// the list); anywhere else it goes on an empty line under the block, as the
/// block handle's Insert below does, so a word is never split by the list.
function openInsertMenu() {
  const view = activeEditorView()
  if (!view || !isEditable) return false
  const { selection, doc, schema } = view.state
  const $end = selection.$to
  const parent = $end.parent
  const tr = view.state.tr
  const inProse = selection instanceof TextSelection && parent.isTextblock && !parent.type.spec.code
  const before = inProse ? parent.textBetween(0, $end.parentOffset, ' ', ' ') : null
  if (inProse && (before === '' || /\s$/.test(before))) {
    tr.setSelection(TextSelection.create(doc, $end.pos))
  } else {
    const after = $end.depth > 0 ? $end.after(1) : selection.to
    tr.insert(after, schema.nodes.paragraph.create())
    tr.setSelection(TextSelection.create(tr.doc, Math.min(after + 1, tr.doc.content.size)))
  }
  tr.insertText('/')
  dispatchBlockEdit(view, tr)
  // The list opens from the caret only while the page has focus, which a press
  // on the host's button had not given it when the `/` was written.
  refreshCaretPickers()
  return true
}

function runBlockSlashCommand(id, from, to) {
  const run = slashBlockCommands[id]
  if (!run || !editor) return
  const view = removeSlashText(from, to)
  if (!view) return
  userHasInteracted = true
  hasUserChanges = true
  try {
    editor.editor.action((ctx) => run(ctx, ctx.get(commandsCtx)))
  } catch (error) {
    post('error', { message: error instanceof Error ? error.message : String(error) })
    return
  }
  carryOnAfterSelectedBlock(view)
  view.focus()
  requestAnimationFrame(publishSelection)
}

/// A block that is not text (the divider) comes out of its command selected,
/// and the next word typed would replace it. The writer carries on in the line
/// after it, made if there is none.
function carryOnAfterSelectedBlock(view) {
  const selection = view.state.selection
  if (!selection.node) return
  const after = selection.to
  const next = view.state.doc.resolve(after).nodeAfter
  const tr = view.state.tr
  if (next?.isTextblock) {
    tr.setSelection(TextSelection.near(tr.doc.resolve(after), 1))
  } else {
    tr.insert(after, view.state.schema.nodes.paragraph.create())
    tr.setSelection(TextSelection.near(tr.doc.resolve(after + 1)))
  }
  view.dispatch(tr.scrollIntoView())
}

// ─── Assistant instructions, prompts and visualizations ─────────────────────
// Three blocks the slash menu adds that Markdown has no name for. Each is
// stored as Markdown every other reader still reads, and drawn here as more:
//
// - **Assistant instructions** is a quote whose first line is the bold words
//   "Assistant instructions". What follows is guidance for whatever works on
//   the page: the model asked to write or change something here is given it
//   with the request (`instructions` on `aiEditRequested`), and Chat and the
//   MCP tools read it as part of the page.
// - **Prompt** is a quote whose first line is the bold word "Prompt": a
//   request the page keeps for its readers. Its "Chat about this" button
//   asks the host to open Chat with that request (`promptRequested`).
// - **Visualization** is a fenced block whose language is `visualization`
//   and whose text is one self-contained HTML document. A host that can run
//   it (`setSlashFeatures({ visualize: true })`) draws it under its source in
//   a frame that cannot reach the page or the network.

const calloutLabels = { instructions: 'Assistant instructions', prompt: 'Prompt', highlight: 'Highlight' }

/// A decoration set that depends only on the document (and, where given, one
/// more thing) is worked out once per document, not on every selection change.
function decorationsOfDocument(compute, inputs = () => '') {
  let lastDoc = null
  let lastInputs = null
  let last = DecorationSet.empty
  return (state) => {
    const current = inputs()
    if (state.doc !== lastDoc || current !== lastInputs) {
      lastDoc = state.doc
      lastInputs = current
      last = compute(state)
    }
    return last
  }
}

/// 'instructions', 'prompt', or null: whether a top-level node is one of the
/// two quote blocks above.
function calloutKind(node) {
  if (node.type.name !== 'blockquote' || node.childCount < 1) return null
  const first = node.firstChild
  if (first.type.name !== 'paragraph' || first.childCount !== 1) return null
  const label = first.firstChild
  if (!label.isText || !label.marks.some((mark) => mark.type.name === 'strong')) return null
  const words = label.text.trim()
  return Object.keys(calloutLabels).find((kind) => calloutLabels[kind] === words) ?? null
}

/// What a callout says under its label, a line to each block.
function calloutBody(node) {
  const lines = []
  node.forEach((child, _offset, index) => {
    if (index > 0) lines.push(child.textContent.trim())
  })
  return lines.filter(Boolean).join('\n')
}

/// The page's standing instructions: every Assistant instructions block, for
/// the model asked to write or change something here. Bounded, so a page of
/// instructions cannot crowd out the passage.
function assistantInstructions(doc) {
  const blocks = []
  doc.forEach((node) => {
    if (calloutKind(node) !== 'instructions') return
    const body = calloutBody(node)
    if (body) blocks.push(body)
  })
  return blocks.join('\n\n').slice(0, 2000)
}

function promptButton(text) {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'artifact-callout-chat'
  button.contentEditable = 'false'
  button.textContent = 'Chat about this'
  button.title = 'Open Chat with this prompt'
  button.addEventListener('mousedown', (event) => event.preventDefault())
  button.addEventListener('click', () => post('promptRequested', { text }))
  return button
}

const calloutPlugin = $prose(() => new Plugin({
  key: new PluginKey('foreverlm-callouts'),
  props: {
    decorations: decorationsOfDocument((state) => {
      const decorations = []
      state.doc.forEach((node, offset) => {
        const kind = calloutKind(node)
        if (!kind) return
        const attributes = { class: 'artifact-callout', 'data-callout': kind }
        // A highlight's colour (Block properties, below); yellow is the plain one.
        if (kind === 'highlight' && node.attrs.color !== defaultProperties('highlight').color) attributes['data-callout-color'] = node.attrs.color
        decorations.push(Decoration.node(offset, offset + node.nodeSize, attributes))
        const text = kind === 'prompt' ? calloutBody(node) : ''
        if (text) {
          decorations.push(Decoration.widget(offset + node.nodeSize - 1, () => promptButton(text), {
            side: 1,
            key: `prompt:${offset}:${text}`,
            ignoreSelection: true,
            stopEvent: () => true,
          }))
        }
      })
      return DecorationSet.create(state.doc, decorations)
    }),
  },
}))

/// A callout written where the `/query` stood: the label in bold, then an empty
/// line to write under it, the caret there.
function insertCalloutBlock(kind, from, to) {
  const view = removeSlashText(from, to)
  if (!view) return
  const { schema } = view.state
  const label = schema.nodes.paragraph.create(null, schema.text(calloutLabels[kind], [schema.marks.strong.create()]))
  const quote = schema.nodes.blockquote.create(null, [label, schema.nodes.paragraph.create()])
  const span = generateSpan(view.state, view.state.selection.from)
  const tr = view.state.tr
  if (span.replace) tr.replaceWith(span.from, span.to, quote)
  else tr.insert(span.from, quote)
  tr.setSelection(TextSelection.create(tr.doc, span.from + 1 + label.nodeSize + 1))
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

// ─── Footnotes ──────────────────────────────────────────────────────────────
// A footnote is a number in the sentence and a note at the foot of the page,
// made the way Substack's editor makes one (docs/docs-design.md, "Footnotes"):
// `/` Footnote or ⌥⌘F puts the next number at the caret and opens its note at
// the bottom of the page with the caret in it; Escape, Return on the note's
// empty last line, or a click on the note's number goes back to the sentence;
// a click on the number in the sentence goes to the note, and the pointer
// resting on it shows the note. Nobody numbers anything: a note's number is
// where it is first cited (footnotes.js), and the page keeps itself that way
// after every edit.
//
// The storage is GFM's, Milkdown's own two nodes: `footnote_reference` (an
// inline atom, `[^1]`) and `footnote_definition` (a block, `[^1]: …`). What
// this section adds is the keeping, one appended transaction after any edit
// that touches a footnote (`keptFootnotes`), so it is one undo with the edit:
//
// - A number and its note are one thing. Deleting the number deletes the note,
//   deleting the note deletes its numbers.
// - The notes stand at the end of the page, in the order they are first cited,
//   and a numeric label is written as the note's number.
// - What arrives from elsewhere fits in. A number copied here carries its note
//   in the copy (`note`, an attribute the clipboard's HTML keeps), so a paste
//   makes a note of its own and a cut and paste moves one; labels a paste
//   brings that the page already uses are renamed; a note pasted without its
//   number becomes the words it held. Substack's, GitHub's and pandoc's
//   footnotes, and a published ForeverLM page's, are read as footnotes, and
//   so are an article's citation numbers, each with its reference as the note.

const footnoteReferenceName = 'footnote_reference'
const footnoteDefinitionName = 'footnote_definition'
const footnotePluginKey = new PluginKey('foreverlm-footnotes')

function isFootnoteReference(node) {
  return node?.type?.name === footnoteReferenceName
}

function isFootnoteDefinition(node) {
  return node?.type?.name === footnoteDefinitionName
}

/// The label a pasted number or note names, read off its link or id the way
/// each writer spells it (`#footnote-1`, `#user-content-fn-1`, `#fn-1`,
/// `#fn1`, `#fn:1`), or its own words; null when it names none.
function pastedFootnoteLabel(...candidates) {
  for (const candidate of candidates) {
    const value = String(candidate ?? '').trim()
    if (!value) continue
    const named = /(?:^|[#-])(?:footnote|fn)(?:-anchor|ref)?[-:]?([A-Za-z0-9_-]+)$/i.exec(value)
    if (named) return named[1]
    if (/^[A-Za-z0-9_-]{1,40}$/.test(value)) return value
  }
  return null
}

/// A citation number pasted from an article (`citationFootnote`), as the
/// footnote's attributes, or false when the link is not one.
function pastedCitation(dom) {
  if (!(dom instanceof HTMLElement)) return false
  const href = dom.getAttribute('href')
  const footnote = citationFootnote({
    words: dom.textContent,
    href,
    address: webReferenceHref(href),
    title: dom.getAttribute('title'),
    ariaLabel: dom.getAttribute('aria-label'),
  })
  return footnote ? { label: footnote.label, note: JSON.stringify(footnote.note) } : false
}

/// The two footnote nodes, as this page draws and reads them. The number is
/// drawn from the label the stylesheet hides (`data-n`, set by the plugin
/// below): what a copy carries to another app is the label, readable there.
function withFootnotes(ctx) {
  ctx.update(footnoteReferenceSchema.key, (base) => (schemaCtx) => {
    const schema = base(schemaCtx)
    const reference = (label) => (label ? { label, note: '' } : false)
    return {
      ...schema,
      attrs: { ...(schema.attrs ?? {}), note: { default: '', validate: 'string' } },
      parseDOM: [
        {
          tag: `sup[data-type="${footnoteReferenceName}"]`,
          getAttrs: (dom) => (dom instanceof HTMLElement
            ? { label: String(dom.dataset.label ?? dom.textContent ?? '').trim(), note: String(dom.dataset.note ?? '') }
            : false),
        },
        // A number pasted from Substack, GitHub, pandoc or a published page.
        {
          tag: 'a.footnote-anchor, a[data-footnote-ref], a.footnote-ref, sup.fn-ref > a, sup.footnote-ref > a',
          priority: 60,
          getAttrs: (dom) => (dom instanceof HTMLElement
            ? reference(pastedFootnoteLabel(dom.getAttribute('href'), dom.textContent))
            : false),
        },
        // A citation number pasted from an article (`pastedCitation`): after
        // the footnote writers above, ahead of the link it would otherwise be.
        {
          tag: 'sup a[href], a[href][role~="doc-biblioref"], a[href][role~="doc-noteref"]',
          priority: 55,
          getAttrs: pastedCitation,
        },
      ],
      toDOM: (node) => [
        'sup',
        {
          'data-type': footnoteReferenceName,
          'data-label': node.attrs.label,
          ...(node.attrs.note ? { 'data-note': node.attrs.note } : {}),
          class: 'artifact-footnote-ref',
        },
        ['span', { class: 'artifact-footnote-label' }, node.attrs.label],
      ],
    }
  })
  ctx.update(footnoteDefinitionSchema.key, (base) => (schemaCtx) => {
    const schema = base(schemaCtx)
    const labelled = (dom, ...candidates) => {
      if (!(dom instanceof HTMLElement)) return false
      const label = pastedFootnoteLabel(...candidates)
      return label ? { label } : false
    }
    return {
      ...schema,
      parseDOM: [
        ...(schema.parseDOM ?? []),
        {
          tag: `div[data-type="${footnoteDefinitionName}"]`,
          contentElement: '.artifact-footnote-body',
          getAttrs: (dom) => (dom instanceof HTMLElement ? { label: String(dom.dataset.label ?? '') } : false),
        },
        // Substack's note: its number, then its words.
        {
          tag: 'div.footnote',
          priority: 60,
          contentElement: '.footnote-content',
          getAttrs: (dom) => {
            const number = dom instanceof HTMLElement ? dom.querySelector('.footnote-number') : null
            return number ? labelled(dom, number.id, number.getAttribute('href')?.replace(/-anchor/, ''), number.textContent) : false
          },
        },
        // GitHub's, pandoc's and a published page's: an item of the list
        // under the article, its back link and the list's own heading dropped.
        {
          tag: 'section.footnotes > ol > li, section[data-footnotes] > ol > li, div.footnotes > ol > li',
          priority: 60,
          getAttrs: (dom) => labelled(dom, dom.id),
        },
        { tag: 'section.footnotes > ol, section[data-footnotes] > ol, div.footnotes > ol', priority: 60, skip: true },
        {
          tag: 'section[data-footnotes] > h2, section.footnotes > h2, section.footnotes > hr, div.footnotes > hr, a[data-footnote-backref], a.footnote-backref, a.footnote-back, a.fn-back',
          priority: 60,
          ignore: true,
        },
      ],
      toDOM: (node) => [
        'div',
        { 'data-type': footnoteDefinitionName, 'data-label': node.attrs.label, class: 'artifact-footnote' },
        ['div', { class: 'artifact-footnote-body' }, 0],
      ],
    }
  })
  // The notes end the page, so the empty line Milkdown keeps after a last
  // block that is not text never goes after them (it would be moved above
  // them again, forever).
  ctx.update(trailingConfig.key, (config) => ({
    ...config,
    shouldAppend: (lastNode, state) => !isFootnoteDefinition(lastNode) && config.shouldAppend(lastNode, state),
  }))
}

/// A document's footnotes: references in reading order, and notes in the
/// order they stand, wherever they stand (a note pasted inside a list, a quote
/// or another note is lifted out to the foot).
const footnoteNodeCache = new WeakMap()

function footnoteNodes(doc) {
  if (footnoteNodeCache.has(doc)) return footnoteNodeCache.get(doc)
  const references = []
  const definitions = []
  const walk = (parent, offset, depth) => {
    parent.forEach((node, childOffset) => {
      const pos = offset + childOffset
      if (isFootnoteReference(node)) {
        references.push({ node, pos, key: footnoteKey(node.attrs.label) })
        return
      }
      if (isFootnoteDefinition(node)) definitions.push({ node, pos, key: footnoteKey(node.attrs.label), topLevel: depth === 0 })
      if (node.content.size && !node.isLeaf) walk(node, pos + 1, depth + 1)
    })
  }
  walk(doc, 0, 0)
  const found = { references, definitions }
  footnoteNodeCache.set(doc, found)
  return found
}

/// The note the position stands in, `{ node, pos }`, or null.
function footnoteDefinitionAround($pos) {
  for (let depth = $pos.depth; depth > 0; depth -= 1) {
    const node = $pos.node(depth)
    if (isFootnoteDefinition(node)) return { node, pos: $pos.before(depth), depth }
  }
  return null
}

/// Each note's number and each reference's, as the page shows them now.
function footnoteNumbers(doc) {
  const { references, definitions } = footnoteNodes(doc)
  const plan = planFootnotes(references.map(({ node }) => node.attrs.label), definitions.map(({ node }) => node.attrs.label))
  const byDefinition = new Map(plan.notes.map((note) => [definitions[note.index].pos, note.number]))
  return { plan, byDefinition, byKey: plan.labels }
}

/// The ranges of `transactions`' final document that they put there, so a
/// footnote inside one is new to the page (a paste, a drop, a rewrite) and one
/// outside is the page's own.
function insertedRanges(transactions) {
  let ranges = []
  for (const transaction of transactions) {
    for (const map of transaction.mapping.maps) {
      ranges = ranges
        .map(([from, to]) => [map.map(from, 1), map.map(to, -1)])
        .filter(([from, to]) => to > from)
      map.forEach((_oldStart, _oldEnd, newStart, newEnd) => {
        if (newEnd > newStart) ranges.push([newStart, newEnd])
      })
    }
  }
  return ranges
}

/// A note's words as JSON, what a copied number carries so the paste can make
/// its note.
function footnoteNoteJSON(definition) {
  return JSON.stringify(definition.content.toJSON())
}

/// A fragment without the notes inside it, which are moved on their own.
function withoutFootnoteDefinitions(fragment) {
  const children = []
  fragment.forEach((child) => {
    if (isFootnoteDefinition(child)) return
    children.push(child.isLeaf || !child.content.size ? child : child.copy(withoutFootnoteDefinitions(child.content)))
  })
  return Fragment.fromArray(children)
}

function noteFromJSON(schema, label, json) {
  const type = schema.nodes[footnoteDefinitionName]
  let content = null
  try {
    content = json ? Fragment.fromJSON(schema, JSON.parse(json)) : null
  } catch {
    content = null
  }
  return (content && type.createAndFill({ label }, content)) || type.create({ label }, schema.nodes.paragraph.create())
}

/// The appended transaction that keeps the page's footnotes whole after
/// `transactions`, or null when they already are. See the section's head for
/// the rules; the steps are: pair what is new with what was there, delete the
/// halves whose other half went, then number and order what is left.
function keptFootnotes(transactions, oldState, newState) {
  const before = footnoteNodes(oldState.doc)
  const after = footnoteNodes(newState.doc)
  if (!before.references.length && !before.definitions.length && !after.references.length && !after.definitions.length) return null
  const { schema } = newState
  const inserted = insertedRanges(transactions)
  const isNew = (pos) => inserted.some(([from, to]) => pos >= from && pos < to)

  const references = after.references.map((entry) => ({ ...entry, fresh: isNew(entry.pos), label: entry.node.attrs.label, drop: false }))
  const definitions = after.definitions.map((entry) => ({ ...entry, fresh: isNew(entry.pos), label: entry.node.attrs.label, drop: false, unwrap: false }))
  const created = []
  const taken = [...references, ...definitions].map((entry) => entry.label)
  let freshCounter = 0
  const freshLabel = () => {
    const label = freshNumericLabel(taken, freshCounter)
    freshCounter = Number(label)
    taken.push(label)
    return label
  }

  // Pair what the edit brought with what the page had.
  const oldReferenceKeys = new Set(references.filter((entry) => !entry.fresh).map((entry) => entry.key))
  const oldDefinitionKeys = new Set(definitions.filter((entry) => !entry.fresh).map((entry) => entry.key))
  const freshKeys = [...new Set([...references, ...definitions].filter((entry) => entry.fresh).sort((a, b) => a.pos - b.pos).map((entry) => entry.key))]
  for (const key of freshKeys) {
    const freshReferences = references.filter((entry) => entry.fresh && entry.key === key)
    const freshDefinitions = definitions.filter((entry) => entry.fresh && entry.key === key)
    const rename = (label) => {
      for (const entry of [...freshReferences, ...freshDefinitions]) {
        entry.label = label
        entry.key = footnoteKey(label)
      }
    }
    if (freshDefinitions.length) {
      // Another note of that name is the page's: these are a pasted pair.
      if (oldDefinitionKeys.has(key)) rename(freshLabel())
      // A second note of one name is a copy nothing reaches.
      for (const extra of freshDefinitions.slice(1)) extra.unwrap = true
      const referenced = freshReferences.length > 0 || (!oldDefinitionKeys.has(key) && oldReferenceKeys.has(key))
      if (!referenced) freshDefinitions[0].unwrap = true
      continue
    }
    // Numbers that came without their note.
    if (oldReferenceKeys.has(key)) {
      // The name is in use by a note of the page's: a copied number (or one
      // from elsewhere) is a note of its own.
      const carried = freshReferences.find((entry) => entry.node.attrs.note)
      const label = freshLabel()
      rename(label)
      created.push(noteFromJSON(schema, label, carried?.node.attrs.note))
    } else if (!oldDefinitionKeys.has(key)) {
      const carried = freshReferences.find((entry) => entry.node.attrs.note)
      created.push(noteFromJSON(schema, freshReferences[0].label, carried?.node.attrs.note))
    }
    // Otherwise the page's note of that name is theirs: moved, or rewritten
    // around them.
  }

  // A number whose note went goes, and a note whose numbers all went.
  const referencedBefore = new Set(before.references.map((entry) => entry.key))
  const notedBefore = new Set(before.definitions.map((entry) => entry.key))
  const referencedNow = new Set(references.map((entry) => entry.key))
  const notedNow = new Set([
    ...definitions.filter((entry) => !entry.unwrap).map((entry) => entry.key),
    ...created.map((node) => footnoteKey(node.attrs.label)),
  ])
  for (const entry of definitions) {
    if (!entry.fresh && referencedBefore.has(entry.key) && !referencedNow.has(entry.key)) entry.drop = true
  }
  for (const entry of references) {
    if (!notedNow.has(entry.key)) {
      if (!entry.fresh && notedBefore.has(entry.key)) entry.drop = true
      else {
        // A number with no note anywhere (only an outside writer makes one):
        // it gets an empty note rather than losing its place.
        created.push(schema.nodes[footnoteDefinitionName].create({ label: entry.label }, schema.nodes.paragraph.create()))
        notedNow.add(entry.key)
      }
    }
  }

  // Number and order what is left.
  const keptReferences = references.filter((entry) => !entry.drop)
  const keptDefinitions = definitions.filter((entry) => !entry.drop && !entry.unwrap)
  const plan = planFootnotes(
    keptReferences.map((entry) => entry.label),
    [...keptDefinitions.map((entry) => entry.label), ...created.map((node) => node.attrs.label)],
  )
  const finalLabel = (entry) => plan.labels.get(entry.key)?.label ?? entry.label
  const ordered = plan.notes.map((note) => ({ note, entry: keptDefinitions[note.index] ?? null, made: note.index >= keptDefinitions.length ? created[note.index - keptDefinitions.length] : null }))

  const relabelReferences = keptReferences.filter((entry) => finalLabel(entry) !== entry.node.attrs.label || entry.node.attrs.note)
  const dropping = [...references.filter((entry) => entry.drop), ...definitions.filter((entry) => entry.drop || entry.unwrap)]
  const tail = []
  for (let index = newState.doc.childCount - 1; index >= 0; index -= 1) {
    if (!isFootnoteDefinition(newState.doc.child(index))) break
    tail.unshift(index)
  }
  const inPlace = created.length === 0
    && !definitions.some((entry) => entry.unwrap)
    && keptDefinitions.every((entry) => entry.topLevel)
    && tail.length === keptDefinitions.length + definitions.filter((entry) => (entry.drop || entry.unwrap) && entry.topLevel).length
    && ordered.every(({ entry }, position) => entry && entry === keptDefinitions[position])
  // The notes follow a line of prose, so there is always somewhere to write
  // between the page and its notes.
  const writable = (node) => Boolean(node?.isTextblock && !node.type.spec.code)
  const firstNote = newState.doc.childCount - tail.length
  const needsLine = inPlace && ordered.length > 0 && !writable(firstNote > 0 ? newState.doc.child(firstNote - 1) : null)
  const relabelDefinitions = ordered.filter(({ note, entry }) => entry && note.label !== entry.node.attrs.label)
  if (!relabelReferences.length && !dropping.length && inPlace && !relabelDefinitions.length && !needsLine) return null

  const tr = newState.tr
  const selectionHead = newState.selection.head
  // The innermost note the caret is in.
  const holding = definitions.findLast((entry) => selectionHead > entry.pos && selectionHead < entry.pos + entry.node.nodeSize) ?? null
  const holdingOffset = holding ? selectionHead - holding.pos : 0
  const holdingCreated = transactions.some((transaction) => transaction.getMeta(footnotePluginKey)?.opened)

  // References first: a relabel keeps every position, a deletion is one atom.
  for (const entry of relabelReferences) {
    tr.setNodeMarkup(entry.pos, null, { ...entry.node.attrs, label: finalLabel(entry), note: '' }, entry.node.marks)
  }
  for (const entry of [...references.filter((item) => item.drop)].sort((a, b) => b.pos - a.pos)) {
    tr.delete(entry.pos, entry.pos + entry.node.nodeSize)
  }
  const mapped = (entry) => tr.mapping.map(entry.pos, 1)
  let holdingNow = null
  if (inPlace) {
    for (const entry of [...dropping.filter((item) => isFootnoteDefinition(item.node))].sort((a, b) => b.pos - a.pos)) {
      const pos = mapped(entry)
      const node = tr.doc.nodeAt(pos)
      if (!node) continue
      if (entry.unwrap) tr.replaceWith(pos, pos + node.nodeSize, node.content)
      else tr.delete(pos, pos + node.nodeSize)
    }
    for (const { note, entry } of ordered) {
      if (!entry || note.label === entry.node.attrs.label) continue
      const pos = mapped(entry)
      const node = tr.doc.nodeAt(pos)
      if (node) tr.setNodeMarkup(pos, null, { ...node.attrs, label: note.label })
    }
    if (holding && !holding.drop && !holding.unwrap) holdingNow = mapped(holding)
  } else {
    // Take every note out (a note pasted alone becomes its words where it
    // landed), then write them back at the end in their order.
    const moving = definitions.map((entry) => ({ entry, pos: mapped(entry) }))
    const nodes = new Map()
    for (const { entry, pos } of moving) nodes.set(entry, tr.doc.nodeAt(pos))
    for (const { entry, pos } of [...moving].sort((a, b) => b.pos - a.pos)) {
      const node = tr.doc.nodeAt(pos)
      if (!node || !isFootnoteDefinition(node)) continue
      if (entry.unwrap) tr.replaceWith(pos, pos + node.nodeSize, node.content)
      else tr.delete(pos, pos + node.nodeSize)
    }
    if (ordered.length && !writable(tr.doc.lastChild)) tr.insert(tr.doc.content.size, schema.nodes.paragraph.create())
    let at = tr.doc.content.size
    for (const { note, entry, made } of ordered) {
      const source = entry ? nodes.get(entry) : made
      if (!source) continue
      const node = source.type.createAndFill({ ...source.attrs, label: note.label }, withoutFootnoteDefinitions(source.content), source.marks)
        ?? source.type.create({ ...source.attrs, label: note.label }, schema.nodes.paragraph.create())
      tr.insert(at, node)
      if (entry && entry === holding) holdingNow = at
      at += node.nodeSize
    }
  }
  if (needsLine) tr.insert(tr.mapping.map(newState.doc.content.size - tail.reduce((size, index) => size + newState.doc.child(index).nodeSize, 0), -1), schema.nodes.paragraph.create())
  if (holdingNow != null) {
    const target = Math.min(holdingNow + holdingOffset, tr.doc.content.size)
    try {
      tr.setSelection(TextSelection.create(tr.doc, target))
      if (holdingCreated) tr.scrollIntoView()
    } catch {
      // The note's words moved under it; the mapped selection stands.
    }
  }
  tr.setMeta(footnotePluginKey, { kept: true })
  // The notes moved, they were not rewritten: their blocks keep their ids.
  tr.setMeta('foreverlm-block-move', true)
  return tr
}

/// A page opened with its notes out of place (written by hand or over MCP) is
/// shown kept: numbered, notes at the foot. Nothing is saved for it and
/// nothing is undone by it; the writer's first edit saves the kept page.
function keepFootnotesOnOpen(view) {
  if (!view) return
  const tr = keptFootnotes([], view.state, view.state)
  if (tr) view.dispatch(tr.setMeta('addToHistory', false))
}

/// A number and a note added at the caret, the caret in the note: what `/`
/// Footnote and ⌥⌘F do. The words selected stay; the number goes after them.
function insertFootnote(view) {
  if (!view || !isEditable) return false
  const { state } = view
  const { schema, selection } = state
  const referenceType = schema.nodes[footnoteReferenceName]
  const definitionType = schema.nodes[footnoteDefinitionName]
  if (!referenceType || !definitionType) return false
  const $at = selection.$to
  if (!$at.parent.isTextblock || $at.parent.type.spec.code || footnoteDefinitionAround($at)) return false
  const { references, definitions } = footnoteNodes(state.doc)
  const label = freshNumericLabel([...references, ...definitions].map(({ node }) => node.attrs.label))
  const tr = state.tr.insert(selection.to, referenceType.create({ label }))
  const end = tr.doc.content.size
  tr.insert(end, definitionType.create({ label }, schema.nodes.paragraph.create()))
  tr.setSelection(TextSelection.create(tr.doc, end + 2))
  tr.setMeta(footnotePluginKey, { opened: label })
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
  return true
}

/// Whether the caret is where a footnote can go: in prose, outside a note.
function caretTakesFootnote(view) {
  const $at = view?.state.selection.$to
  return Boolean($at && $at.parent.isTextblock && !$at.parent.type.spec.code && !footnoteDefinitionAround($at))
}

/// The `/` row: the `/footnote` typed out, with the space before it when it
/// followed a word (`word /fn` makes `word¹`), then the footnote. Run from the
/// host (`runSlashRow`), nothing was typed and nothing is taken out.
function insertFootnoteForSlash(from, to) {
  const view = activeEditorView()
  if (!view) return
  const doc = view.state.doc
  const $from = doc.resolve(Math.max(0, Math.min(from, doc.content.size)))
  const before = $from.parent.isTextblock ? $from.parent.textBetween(0, $from.parentOffset, ' ', ' ') : ''
  const start = to > from && /\S $/.test(before) ? from - 1 : from
  if (removeSlashText(start, to)) insertFootnote(view)
}

/// Brings the caret to the note behind a number: the end of its words.
function goToFootnote(view, key) {
  const definition = footnoteNodes(view.state.doc).definitions.find((entry) => entry.key === key)
  if (!definition) return false
  const end = Selection.findFrom(view.state.doc.resolve(definition.pos + definition.node.nodeSize - 1), -1, true)
  const tr = view.state.tr.setMeta(footnotePluginKey, { target: definition.pos })
  if (end) tr.setSelection(end)
  view.dispatch(tr.scrollIntoView())
  view.focus()
  scheduleFootnoteTargetClear()
  return true
}

/// Back from a note to its first number: the caret just after it.
function goToFootnoteReference(view, key) {
  const reference = footnoteNodes(view.state.doc).references.find((entry) => entry.key === key)
  if (!reference) return false
  const tr = view.state.tr
    .setSelection(TextSelection.create(view.state.doc, reference.pos + reference.node.nodeSize))
    .setMeta(footnotePluginKey, { target: reference.pos })
  view.dispatch(tr.scrollIntoView())
  view.focus()
  scheduleFootnoteTargetClear()
  return true
}

let footnoteTargetTimer = null

/// The number or note just gone to is lit for a moment, so the eye finds it.
function scheduleFootnoteTargetClear() {
  clearTimeout(footnoteTargetTimer)
  footnoteTargetTimer = setTimeout(() => {
    const view = activeEditorView()
    if (view && footnotePluginKey.getState(view.state)?.target != null) {
      view.dispatch(view.state.tr.setMeta(footnotePluginKey, { target: null }).setMeta('addToHistory', false))
    }
  }, 1400)
}

/// A note deleted from the bottom of the page: it and every number of it, the
/// caret where its first number stood.
function deleteFootnote(view, definition) {
  const { references } = footnoteNodes(view.state.doc)
  const own = references.filter((entry) => entry.key === footnoteKey(definition.node.attrs.label))
  const tr = view.state.tr.delete(definition.pos, definition.pos + definition.node.nodeSize)
  for (const entry of [...own].sort((a, b) => b.pos - a.pos)) {
    const pos = tr.mapping.map(entry.pos, 1)
    tr.delete(pos, pos + 1)
  }
  const first = own[0] ? tr.mapping.map(own[0].pos, -1) : null
  if (first != null) tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(first, tr.doc.content.size)), -1))
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
}

/// The keys of a note: ⌥⌘F anywhere in prose; Escape, and Return on a note's
/// empty last line, back to the sentence; Backspace at the very start of an
/// empty note takes the footnote away, and at the start of one with words, or
/// Delete at the end of a note or of the line before the notes, does nothing,
/// so a note's words never run into the page's or another note's.
function handleFootnoteKey(view, event) {
  if (!isEditable) return false
  if (event.code === 'KeyF' && event.altKey && (event.metaKey || event.ctrlKey) && !event.shiftKey) {
    return insertFootnote(view)
  }
  const { selection, doc } = view.state
  if (!selection.empty) return false
  const $at = selection.$from
  const note = footnoteDefinitionAround($at)
  const plain = !event.altKey && !event.metaKey && !event.ctrlKey && !event.shiftKey
  if (note) {
    const key = footnoteKey(note.node.attrs.label)
    if (event.key === 'Escape' && !linkPickerState) return goToFootnoteReference(view, key)
    if (event.key === 'Enter' && plain && $at.parent.isTextblock && $at.parent.content.size === 0
      && $at.depth === note.depth + 1 && $at.index(note.depth) === note.node.childCount - 1) {
      if (note.node.childCount > 1) {
        view.dispatch(view.state.tr.delete($at.before(), $at.after()))
      }
      return goToFootnoteReference(view, key)
    }
    if (event.key === 'Backspace' && plain) {
      const start = Selection.findFrom(doc.resolve(note.pos + 1), 1, true)
      if (start && start.from === $at.pos) {
        if (note.node.childCount === 1 && note.node.firstChild.content.size === 0) deleteFootnote(view, note)
        return true
      }
    }
    if (event.key === 'Delete' && plain) {
      const end = Selection.findFrom(doc.resolve(note.pos + note.node.nodeSize - 1), -1, true)
      if (end && end.from === $at.pos) return true
    }
    return false
  }
  if (event.key === 'Delete' && plain && $at.parent.isTextblock && $at.parentOffset === $at.parent.content.size && $at.depth > 0) {
    const next = Selection.findFrom(doc.resolve($at.after()), 1, true)
    if (next && footnoteDefinitionAround(next.$from)) return true
  }
  return false
}

let footnoteCard = null
let footnoteCardTimer = null

function ensureFootnoteCard() {
  if (footnoteCard) return footnoteCard
  footnoteCard = document.createElement('div')
  footnoteCard.className = 'artifact-footnote-card'
  footnoteCard.setAttribute('role', 'tooltip')
  footnoteCard.hidden = true
  document.body.append(footnoteCard)
  return footnoteCard
}

/// The note behind a number, shown under it while the pointer rests there, as
/// a published page shows it: its words, without going down to the foot.
function showFootnoteCard(view, element) {
  const key = footnoteKey(element.dataset.label)
  const definition = footnoteNodes(view.state.doc).definitions.find((entry) => entry.key === key)
  const body = definition ? view.nodeDOM(definition.pos)?.querySelector?.('.artifact-footnote-body') : null
  if (!body) return
  const card = ensureFootnoteCard()
  const copy = body.cloneNode(true)
  for (const node of copy.querySelectorAll('[contenteditable]')) node.removeAttribute('contenteditable')
  card.replaceChildren(...copy.childNodes)
  if (!card.textContent.trim()) card.textContent = 'Empty note'
  card.classList.toggle('is-empty', !body.textContent.trim())
  card.hidden = false
  const rect = element.getBoundingClientRect()
  const width = card.offsetWidth
  const height = card.offsetHeight
  card.style.left = `${Math.max(8, Math.min(rect.left + rect.width / 2 - width / 2, window.innerWidth - width - 8))}px`
  const below = rect.bottom + 8
  card.style.top = `${below + height > window.innerHeight - 8 && rect.top - height - 8 > 8 ? rect.top - height - 8 : below}px`
}

function hideFootnoteCard() {
  clearTimeout(footnoteCardTimer)
  footnoteCardTimer = null
  if (footnoteCard) footnoteCard.hidden = true
}

/// Copy, cut and drag: a number whose note is not in the copy carries the
/// note's words, so wherever it is pasted it has its note.
function withFootnoteNotes(fragment, notes) {
  const children = []
  fragment.forEach((node) => {
    if (isFootnoteReference(node)) {
      const note = notes.get(footnoteKey(node.attrs.label))
      children.push(note && note !== node.attrs.note ? node.type.create({ ...node.attrs, note }, null, node.marks) : node)
    } else if (!node.isLeaf && node.content.size) {
      children.push(node.copy(withFootnoteNotes(node.content, notes)))
    } else {
      children.push(node)
    }
  })
  return Fragment.fromArray(children)
}

/// The notes of `doc` that the numbers in `fragment` cite and `fragment` does
/// not hold itself, by key, as `note` values.
function notesForFragment(doc, fragment) {
  const cited = new Set()
  const inside = new Set()
  fragment.descendants((node) => {
    if (isFootnoteReference(node)) cited.add(footnoteKey(node.attrs.label))
    if (isFootnoteDefinition(node)) inside.add(footnoteKey(node.attrs.label))
    return true
  })
  const notes = new Map()
  if (!cited.size) return notes
  for (const entry of footnoteNodes(doc).definitions) {
    if (cited.has(entry.key) && !inside.has(entry.key) && !notes.has(entry.key)) notes.set(entry.key, footnoteNoteJSON(entry.node))
  }
  return notes
}

const footnotePlugin = $prose(() => new Plugin({
  key: footnotePluginKey,
  state: {
    init: () => ({ target: null }),
    apply(tr, value) {
      const meta = tr.getMeta(footnotePluginKey)
      if (meta && 'target' in meta) return { target: meta.target }
      if (value.target == null || !tr.docChanged) return value
      const mapped = tr.mapping.mapResult(value.target, 1)
      return { target: mapped.deleted ? null : mapped.pos }
    },
  },
  appendTransaction(transactions, oldState, newState) {
    if (applyingExternalMarkdown || !transactions.some((tr) => tr.docChanged)) return null
    if (transactions.every((tr) => tr.getMeta(footnotePluginKey)?.kept)) return null
    return keptFootnotes(transactions, oldState, newState)
  },
  props: {
    decorations: (() => {
      const numbers = decorationsOfDocument((state) => {
        const { references, definitions } = footnoteNodes(state.doc)
        if (!references.length && !definitions.length) return DecorationSet.empty
        const { byDefinition, byKey } = footnoteNumbers(state.doc)
        const decorations = []
        for (const entry of references) {
          const number = byKey.get(entry.key)?.number
          decorations.push(Decoration.node(entry.pos, entry.pos + entry.node.nodeSize, number ? { 'data-n': String(number) } : { class: 'is-unresolved', 'data-n': '?' }))
        }
        let first = true
        for (const entry of [...definitions].sort((a, b) => a.pos - b.pos)) {
          const attributes = { 'data-n': String(byDefinition.get(entry.pos) ?? '') }
          if (first && entry.topLevel) attributes.class = 'is-first'
          if (!byKey.has(entry.key) || !references.some((reference) => reference.key === entry.key)) attributes['data-unreferenced'] = 'true'
          first = false
          decorations.push(Decoration.node(entry.pos, entry.pos + entry.node.nodeSize, attributes))
        }
        return DecorationSet.create(state.doc, decorations)
      })
      return (state) => {
        const target = footnotePluginKey.getState(state)?.target
        const node = target == null ? null : state.doc.nodeAt(target)
        if (!node || !(isFootnoteReference(node) || isFootnoteDefinition(node))) return numbers(state)
        return numbers(state).add(state.doc, [Decoration.node(target, target + node.nodeSize, { class: 'is-target' })])
      }
    })(),
    handleKeyDown: (view, event) => handleFootnoteKey(view, event),
    handleClickOn(view, _pos, node, _nodePos, event, direct) {
      if (!direct || event.button !== 0 || event.shiftKey || event.metaKey || event.ctrlKey) return false
      if (!isFootnoteReference(node)) return false
      hideFootnoteCard()
      return goToFootnote(view, footnoteKey(node.attrs.label))
    },
    transformCopied(slice, view) {
      const notes = notesForFragment(view.state.doc, slice.content)
      if (!notes.size) return slice
      return new Slice(withFootnoteNotes(slice.content, notes), slice.openStart, slice.openEnd)
    },
    handleDOMEvents: {
      // The note's number, drawn in the margin of the note, goes back to the
      // sentence. It is the note's own box (`::before`), so a press left of
      // the note's words is a press on it.
      mousedown(view, event) {
        const element = event.target instanceof Element ? event.target.closest('.artifact-footnote') : null
        if (!element || event.button !== 0) return false
        const body = element.querySelector('.artifact-footnote-body')
        if (!body || event.clientX >= body.getBoundingClientRect().left) return false
        event.preventDefault()
        return goToFootnoteReference(view, footnoteKey(element.dataset.label))
      },
      mouseover(view, event) {
        const element = event.target instanceof Element ? event.target.closest('sup.artifact-footnote-ref') : null
        if (!element) return false
        clearTimeout(footnoteCardTimer)
        footnoteCardTimer = setTimeout(() => showFootnoteCard(view, element), 160)
        return false
      },
      mouseout(_view, event) {
        const element = event.target instanceof Element ? event.target.closest('sup.artifact-footnote-ref') : null
        if (element && !element.contains(event.relatedTarget)) hideFootnoteCard()
        return false
      },
      keydown() {
        hideFootnoteCard()
        return false
      },
    },
  },
}))

/// What a proposal from the AI means by `[^1]`: the page's own note 1, so it is
/// read with the page's notes beside it (a `[^1]` with no note reads as
/// text). Those stand-ins are dropped again; a note the AI wrote itself is
/// kept apart and added at the foot. Each number carries its note's words,
/// so a number written next to the passage rather than over it gets a copy of
/// the note, as a paste would.
const footnoteStandIn = 'foreverlm-footnote-stand-in'

function footnoteStandIns(doc) {
  const { definitions } = footnoteNodes(doc)
  if (!definitions.length) return ''
  return `\n\n${definitions.map((entry) => `[^${entry.node.attrs.label}]: ${footnoteStandIn}`).join('\n\n')}\n`
}

function separatedFootnotes(parsed, doc) {
  const notes = []
  const kept = []
  parsed.forEach((node) => {
    if (!isFootnoteDefinition(node)) kept.push(node)
    else if (node.textContent.trim() !== footnoteStandIn) notes.push(node)
  })
  const pageNotes = new Map(footnoteNodes(doc).definitions.map((entry) => [entry.key, footnoteNoteJSON(entry.node)]))
  const content = withFootnoteNotes(Fragment.fromArray(kept), pageNotes)
  return { content: parsed.type.create(parsed.attrs, content), notes }
}

// ─── Block properties ───────────────────────────────────────────────────────
// A table's width and column fit, a highlight's colour: properties Markdown has
// no word for, kept in the page text as a one-line comment after the block
// (`<!--fl {"width":"full"}-->`; block-properties.js has the grammar and
// docs/docs-design.md, "Block properties", the reasons). Here they are node
// attributes: a remark pass hands each block the comment after it before the
// page is built, and the block's serializer writes it back after the block, so
// nothing of the comment is ever text on the page. Because they are attributes
// of the node, a block carries them through copy and paste, a drag with the
// block handle, Duplicate and undo, and the notes graph's ids are untouched.
// A block at its defaults has no comment, and a page without any serializes as
// it always did.
//
// Only top-level blocks take them: the pass reads the page's own sequence of
// blocks, and a table inside a list item writes none.

const blockPropertiesRemark = $remark('foreverlm-block-properties', () => () => attachBlockProperties)

/// The blocks that take properties, and the node attribute each property is.
const propertyBlocks = [
  { schema: tableSchema, kind: 'table', names: ['width', 'fit'], takes: () => true },
  { schema: blockquoteSchema, kind: 'highlight', names: ['color'], takes: (node) => calloutKind(node) === 'highlight' },
]

/// A node's DOM spec with `attrs` added to its outer element.
function withAttributesOnDOM(spec, attrs) {
  if (!Array.isArray(spec) || Object.keys(attrs).length === 0) return spec
  const [tag, second, ...rest] = spec
  const isAttrs = second && typeof second === 'object' && !Array.isArray(second) && !(second instanceof Node)
  return isAttrs ? [tag, { ...second, ...attrs }, ...rest] : [tag, attrs, ...spec.slice(1)]
}

/// Give tables and highlights their properties: read off the page's Markdown
/// by the pass above, kept as attributes, written back after the block.
/// Milkdown's own runners do the rest, so a block with none reads and writes
/// as it did.
function withBlockProperties(ctx) {
  for (const { schema: schemaSlice, kind, names, takes } of propertyBlocks) {
    const defaults = defaultProperties(kind)
    ctx.update(schemaSlice.key, (base) => (schemaCtx) => {
      const schema = base(schemaCtx)
      const parseRunner = schema.parseMarkdown.runner
      const serializeRunner = schema.toMarkdown.runner
      const attrs = { ...(schema.attrs ?? {}) }
      for (const name of names) attrs[name] = { default: defaults[name], validate: 'string' }
      return {
        ...schema,
        attrs,
        // What a paste reads back: a block pasted into a page keeps them.
        parseDOM: (schema.parseDOM ?? []).map((rule) => ({
          ...rule,
          getAttrs: (dom) => {
            const read = typeof rule.getAttrs === 'function' ? rule.getAttrs(dom) : (rule.attrs ?? null)
            if (read === false) return false
            const found = {}
            for (const name of names) {
              const value = dom instanceof HTMLElement ? dom.getAttribute(`data-fl-${name}`) : null
              found[name] = blockPropertyValues[kind][name].includes(value) ? value : defaults[name]
            }
            return { ...(read ?? {}), ...found }
          },
        })),
        toDOM: (node) => withAttributesOnDOM(schema.toDOM(node), Object.fromEntries(
          names.filter((name) => node.attrs[name] !== defaults[name]).map((name) => [`data-fl-${name}`, node.attrs[name]])
        )),
        parseMarkdown: {
          match: schema.parseMarkdown.match,
          runner: (state, node, type) => {
            parseRunner(state, node, type)
            const given = node.flProperties
            if (!given) return
            const content = state.top()?.content
            const built = content?.at(-1)
            if (built?.type !== type) return
            const next = {}
            for (const name of names) next[name] = given[name]
            content[content.length - 1] = type.create({ ...built.attrs, ...next }, built.content, built.marks)
          },
        },
        toMarkdown: {
          match: schema.toMarkdown.match,
          runner: (state, node) => {
            serializeRunner(state, node)
            // Written after the block, as the page's next block.
            if (state.top()?.type !== 'root' || !takes(node)) return
            const comment = propertyComment(kind, node.attrs)
            if (comment) state.addNode('html', undefined, comment)
          },
        },
      }
    })
  }
}

/// How a table is drawn: its width and column fit, as attributes on the
/// table's element for the stylesheet. A table at its defaults carries none,
/// which is today's look.
const blockPropertiesPlugin = $prose(() => new Plugin({
  key: new PluginKey('foreverlm-block-properties'),
  props: {
    decorations: decorationsOfDocument((state) => {
      const decorations = []
      const defaults = defaultProperties('table')
      state.doc.forEach((node, offset) => {
        if (node.type.name !== 'table') return
        const attributes = {}
        if (node.attrs.width !== defaults.width) attributes['data-table-width'] = node.attrs.width
        if (node.attrs.fit !== defaults.fit) attributes['data-table-fit'] = node.attrs.fit
        if (Object.keys(attributes).length) decorations.push(Decoration.node(offset, offset + node.nodeSize, attributes))
      })
      return DecorationSet.create(state.doc, decorations)
    }),
  },
}))

/// The words of the block menu's property rows: one list per property, one row
/// per value, in the order the grammar lists them.
const propertyMenus = {
  width: {
    icon: 'width',
    title: 'Width',
    values: { normal: 'Normal', flexible: 'Flexible', full: 'Full width' },
  },
  fit: {
    icon: 'columns',
    title: 'Column fit',
    values: { readability: 'For readability', even: 'Distribute columns evenly' },
  },
  color: {
    icon: 'palette',
    title: 'Colour',
    values: { yellow: 'Yellow', red: 'Red', orange: 'Orange', green: 'Green', blue: 'Blue', purple: 'Purple', gray: 'Gray' },
  },
}

/// A property of the block at `target.from`, set in one step (one undo).
function setBlockProperty(view, target, name, value) {
  const node = view.state.doc.nodeAt(target.from)
  if (!node || node.attrs[name] === undefined || node.attrs[name] === value) return
  dispatchBlockEdit(view, view.state.tr.setNodeMarkup(target.from, null, { ...node.attrs, [name]: value }))
}

/// A colour's dot, for the Colour list: the colour the highlight is drawn in.
function colorSwatch(color) {
  const swatch = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  swatch.setAttribute('viewBox', '0 0 16 16')
  swatch.setAttribute('width', '16')
  swatch.setAttribute('height', '16')
  swatch.setAttribute('aria-hidden', 'true')
  const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle')
  dot.setAttribute('cx', '8')
  dot.setAttribute('cy', '8')
  dot.setAttribute('r', '4.6')
  dot.style.fill = `var(--artifact-highlight-${color})`
  swatch.append(dot)
  return swatch
}

/// The menu rows for a block's properties: one list per property, each value a
/// row with a check on the one it has. Empty for a block that takes none.
function blockPropertyRows(view, target, menu) {
  const node = target.item ? null : target.node
  let kind = null
  if (node?.type.name === 'table') kind = 'table'
  else if (node && calloutKind(node) === 'highlight') kind = 'highlight'
  if (!kind) return []
  const rows = []
  for (const name of Object.keys(blockPropertyValues[kind])) {
    const spec = propertyMenus[name]
    const items = Object.entries(spec.values).map(([value, title]) => {
      const row = blockMenuRow(name === 'color' ? colorSwatch(value) : spec.icon, title, () => setBlockProperty(view, target, name, value), { check: true })
      row.setAttribute('aria-checked', String(node.attrs[name] === value))
      return row
    })
    rows.push(...blockMenuGroup(menu, target, spec.icon, spec.title, items))
  }
  rows.push(blockMenuSeparator())
  return rows
}

/// A new row under a table's last one, the caret in its first cell.
function insertTableRowBelow(view, target) {
  const table = view.state.doc.nodeAt(target.from)
  if (table?.type.name !== 'table') return
  const commands = editor.editor.action((ctx) => ctx.get(commandsCtx))
  commands.call(selectRowCommand.key, { pos: target.from + 1, index: table.childCount - 1 })
  commands.call(addRowAfterCommand.key)
  const grown = view.state.doc.nodeAt(target.from)
  if (!grown) return
  const lastRow = target.from + grown.nodeSize - 1 - grown.lastChild.nodeSize
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(lastRow + 2), 1)).scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

// ── The block handle ────────────────────────────────────────────────────────
// ChatGPT's Pages shows a grip beside the block under the pointer: press and
// drag it to move the block (a heading takes its whole section), press and
// release for the block's menu. The grip shows only under the pointer and goes
// while typing ("Quiet chrome", docs/ui-design.md), so a page at rest stays as
// bare as before. A block is a top-level block, or an item of a list: an item
// moves among its own list's items and brings the items nested under it.
//
// The menu: Turn into, Insert below (an empty line with the `/` list open),
// Duplicate, Copy as Markdown, Copy block reference (where the host keeps the
// notes graph), Delete. A table's rows and columns have Crepe's own handles;
// its menu is the same list.

let blockHandle = null
let blockHandleGrip = null
let blockMenu = null
let blockDropLine = null
/// The block under the pointer: `{ from, to, node, item }`, `to` past a
/// heading's section; null when the pointer is nowhere near one.
let blockHandleTarget = null
let blockHandleFrame = 0
let blockHandlePointer = null
let blockHandleTyping = false
let blockDrag = null

/// The block at a vertical position among the children of `parent` (a doc or a
/// list), or null. A list item answers with the deepest item the pointer is in.
function blockAtHeight(view, parent, parentPos, y, depth = 0) {
  let found = null
  parent.forEach((node, offset) => {
    if (found) return
    const pos = parentPos + offset
    const element = view.nodeDOM(pos)
    if (!(element instanceof HTMLElement)) return
    const rect = element.getBoundingClientRect()
    if (y < rect.top - 3 || y > rect.bottom + 6) return
    if (node.type.name === 'bullet_list' || node.type.name === 'ordered_list') {
      found = blockAtHeight(view, node, pos + 1, y, depth + 1)
      return
    }
    if (node.type.name === 'list_item') {
      node.forEach((child, childOffset) => {
        if (found || (child.type.name !== 'bullet_list' && child.type.name !== 'ordered_list')) return
        found = blockAtHeight(view, child, pos + 1 + childOffset + 1, y, depth + 1)
      })
      found ??= { from: pos, to: pos + node.nodeSize, node, item: true, element }
      return
    }
    found = { from: pos, to: pos + node.nodeSize, node, item: false, element }
  })
  return found
}

/// A heading's section: the heading and what follows it, up to the next
/// heading of the same or a higher rank (or the end of the page).
function headingSectionEnd(doc, target) {
  if (target.item || target.node.type.name !== 'heading') return target.to
  const level = target.node.attrs?.level ?? 1
  let end = target.to
  let ended = false
  doc.forEach((node, offset) => {
    if (ended || offset < target.to) return
    if ((node.type.name === 'heading' && (node.attrs?.level ?? 1) <= level) || isFootnoteDefinition(node)) {
      ended = true
      return
    }
    end = offset + node.nodeSize
  })
  return end
}

function ensureBlockHandle() {
  if (blockHandle) return blockHandle
  blockHandle = document.createElement('div')
  blockHandle.className = 'artifact-block-handle'
  blockHandle.hidden = true
  blockHandleGrip = document.createElement('button')
  blockHandleGrip.type = 'button'
  blockHandleGrip.className = 'artifact-block-grip'
  blockHandleGrip.title = 'Drag to move, click for options'
  blockHandleGrip.setAttribute('aria-label', 'Block options')
  blockHandleGrip.setAttribute('aria-haspopup', 'menu')
  blockHandleGrip.append(slashIcon('grip', 14))
  blockHandleGrip.addEventListener('pointerdown', beginBlockPress)
  blockHandle.append(blockHandleGrip)
  document.body.append(blockHandle)
  return blockHandle
}

function hideBlockHandle() {
  if (blockHandle) blockHandle.hidden = true
  blockHandleTarget = null
}

/// Beside the first line of the block, in the gutter to its left.
function positionBlockHandle() {
  const handle = blockHandle
  const view = activeEditorView()
  const target = blockHandleTarget
  if (!handle || !view || !target || !isEditable) {
    if (handle) handle.hidden = true
    return
  }
  const element = view.nodeDOM(target.from)
  if (!(element instanceof HTMLElement)) {
    handle.hidden = true
    return
  }
  const rect = element.getBoundingClientRect()
  let center = rect.top + 14
  try {
    const first = target.node.type.name === 'table' ? null : view.coordsAtPos(Math.min(target.from + (target.item ? 2 : 1), target.to - 1))
    if (first && first.top >= rect.top - 2 && first.bottom <= rect.bottom + 2) center = (first.top + first.bottom) / 2
  } catch {
    // An atom block (a picture, a divider): the block's top edge will do.
  }
  const height = 22
  handle.style.left = `${Math.max(2, Math.round(rect.left - 26))}px`
  handle.style.top = `${Math.round(center - height / 2)}px`
  handle.hidden = false
}

function updateBlockHandleFromPointer() {
  blockHandleFrame = 0
  const pointer = blockHandlePointer
  const view = activeEditorView()
  if (!pointer || !view || !isEditable || blockDrag || (blockMenu && !blockMenu.hidden)) return
  if (blockHandleTyping || pointer.buttons !== 0) {
    hideBlockHandle()
    return
  }
  const bounds = view.dom.getBoundingClientRect()
  const insideGutter = pointer.x >= bounds.left - 44 && pointer.x <= bounds.right + 4
  const overHandle = blockHandle && !blockHandle.hidden && blockHandle.contains(pointer.element)
  if (overHandle) return
  if (!insideGutter || pointer.y < bounds.top - 4 || pointer.y > bounds.bottom + 4) {
    hideBlockHandle()
    return
  }
  const next = blockAtHeight(view, view.state.doc, 0, pointer.y)
  // Between two blocks, the handle stays with the last one it was on.
  if (!next) return
  // The notes keep the order of the page's numbers: nothing to drag or turn.
  if (isFootnoteDefinition(next.node)) {
    hideBlockHandle()
    return
  }
  if (!blockHandleTarget || blockHandleTarget.from !== next.from || blockHandleTarget.to !== next.to) {
    blockHandleTarget = { ...next, to: headingSectionEnd(view.state.doc, next) }
  }
  ensureBlockHandle()
  positionBlockHandle()
}

document.addEventListener('pointermove', (event) => {
  if (!isEditable || event.pointerType === 'touch') return
  const moved = !blockHandlePointer || Math.abs(event.clientX - blockHandlePointer.x) + Math.abs(event.clientY - blockHandlePointer.y) > 2
  blockHandlePointer = { x: event.clientX, y: event.clientY, buttons: event.buttons, element: event.target }
  if (moved) blockHandleTyping = false
  if (!blockHandleFrame) blockHandleFrame = requestAnimationFrame(updateBlockHandleFromPointer)
}, { passive: true })

document.documentElement.addEventListener('mouseleave', () => {
  if (!blockDrag && !(blockMenu && !blockMenu.hidden)) hideBlockHandle()
})

document.addEventListener('keydown', (event) => {
  if (event.key.length !== 1 && event.key !== 'Enter' && event.key !== 'Backspace') return
  blockHandleTyping = true
  if (!blockDrag && !(blockMenu && !blockMenu.hidden)) hideBlockHandle()
}, true)

window.addEventListener('scroll', () => {
  if (blockHandleTarget && !blockDrag) positionBlockHandle()
}, { passive: true })

/// Where a block dropped at `y` would land: the boundary between the siblings
/// of `target` nearest to it, never inside the moving range. `{ pos, y, left,
/// right }` in the page's coordinates.
function blockDropSlot(view, target, y) {
  const $from = view.state.doc.resolve(target.from)
  const parent = $from.parent
  const start = $from.start()
  const stops = []
  let parentRect = null
  parent.forEach((node, offset) => {
    const pos = start + offset
    const element = view.nodeDOM(pos)
    if (!(element instanceof HTMLElement)) return
    const rect = element.getBoundingClientRect()
    stops.push({ pos, top: rect.top, bottom: rect.bottom, end: pos + node.nodeSize, left: rect.left, right: rect.right })
  })
  if (stops.length === 0) return null
  parentRect = stops.reduce((box, stop) => ({
    left: Math.min(box.left, stop.left),
    right: Math.max(box.right, stop.right),
  }), { left: Infinity, right: -Infinity })
  const slots = stops.map((stop, index) => ({
    pos: stop.pos,
    y: index === 0 ? stop.top : (stops[index - 1].bottom + stop.top) / 2,
  }))
  const last = stops[stops.length - 1]
  slots.push({ pos: last.end, y: last.bottom })
  let best = null
  for (const slot of slots) {
    if (!best || Math.abs(slot.y - y) < Math.abs(best.y - y)) best = slot
  }
  return best ? { ...best, left: parentRect.left, right: parentRect.right } : null
}

function ensureBlockDropLine() {
  if (blockDropLine) return blockDropLine
  blockDropLine = document.createElement('div')
  blockDropLine.className = 'artifact-block-drop-line'
  blockDropLine.hidden = true
  document.body.append(blockDropLine)
  return blockDropLine
}

/// The siblings a target covers: the block, or a heading and its section.
function blockSiblings(view, target) {
  const $from = view.state.doc.resolve(target.from)
  const start = $from.start()
  const siblings = []
  $from.parent.forEach((node, offset) => {
    const pos = start + offset
    if (pos >= target.from && pos < target.to) siblings.push({ node, pos })
  })
  return siblings
}

function blockElements(view, target) {
  return blockSiblings(view, target)
    .map(({ pos }) => view.nodeDOM(pos))
    .filter((element) => element instanceof HTMLElement)
}

function beginBlockPress(event) {
  const target = blockHandleTarget
  const view = activeEditorView()
  if (event.button !== 0 || !target || !view || !isEditable) return
  event.preventDefault()
  closeBlockMenu()
  const grip = event.currentTarget
  grip.setPointerCapture(event.pointerId)
  const press = { x: event.clientX, y: event.clientY, target, slot: null, moved: false, elements: [], scroll: 0 }
  const frame = () => {
    if (!blockDrag) return
    if (blockDrag.scroll !== 0) window.scrollBy(0, blockDrag.scroll)
    blockDrag.frame = requestAnimationFrame(frame)
  }
  const move = (moveEvent) => {
    if (!press.moved && Math.abs(moveEvent.clientX - press.x) + Math.abs(moveEvent.clientY - press.y) < 5) return
    if (!press.moved) {
      press.moved = true
      blockDrag = press
      document.body.classList.add('artifact-block-dragging')
      press.elements = blockElements(view, target)
      for (const element of press.elements) element.classList.add('artifact-block-dragging-source')
      press.frame = requestAnimationFrame(frame)
    }
    press.scroll = moveEvent.clientY < 56 ? -14 : moveEvent.clientY > window.innerHeight - 56 ? 14 : 0
    press.pointerY = moveEvent.clientY
    const slot = blockDropSlot(view, target, moveEvent.clientY + 0)
    press.slot = slot
    const line = ensureBlockDropLine()
    if (!slot) {
      line.hidden = true
      return
    }
    line.style.left = `${Math.round(slot.left)}px`
    line.style.width = `${Math.round(slot.right - slot.left)}px`
    line.style.top = `${Math.round(slot.y - 1)}px`
    line.hidden = false
    blockHandle.style.top = `${Math.round(moveEvent.clientY - 11)}px`
  }
  const finish = (upEvent) => {
    grip.removeEventListener('pointermove', move)
    grip.removeEventListener('pointerup', finish)
    grip.removeEventListener('pointercancel', finish)
    try { grip.releasePointerCapture(upEvent.pointerId) } catch { /* already released */ }
    if (!press.moved) {
      openBlockMenu(target)
      return
    }
    cancelAnimationFrame(press.frame)
    blockDrag = null
    document.body.classList.remove('artifact-block-dragging')
    for (const element of press.elements) element.classList.remove('artifact-block-dragging-source')
    if (blockDropLine) blockDropLine.hidden = true
    if (upEvent.type === 'pointerup' && press.slot) moveBlock(view, target, press.slot.pos)
    hideBlockHandle()
  }
  grip.addEventListener('pointermove', move)
  grip.addEventListener('pointerup', finish)
  grip.addEventListener('pointercancel', finish)
}

/// Move `target`'s range to the boundary `dropPos` among its siblings. One
/// transaction, so one undo; the blocks keep their ids (`foreverlm-block-move`).
function moveBlock(view, target, dropPos) {
  if (dropPos >= target.from && dropPos <= target.to) return
  const { state } = view
  const content = state.doc.slice(target.from, target.to).content
  const tr = state.tr
  tr.delete(target.from, target.to)
  const at = tr.mapping.map(dropPos)
  tr.insert(at, content)
  tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(at + 1, tr.doc.content.size)), 1))
  tr.setMeta('foreverlm-block-move', true)
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

// The menu.

function ensureBlockMenu() {
  if (blockMenu) return blockMenu
  blockMenu = document.createElement('div')
  blockMenu.className = 'artifact-selection-block-menu artifact-block-menu'
  blockMenu.setAttribute('role', 'menu')
  blockMenu.setAttribute('aria-label', 'Block options')
  blockMenu.hidden = true
  blockMenu.addEventListener('pointerdown', (event) => event.preventDefault())
  document.body.append(blockMenu)
  document.addEventListener('pointerdown', (event) => {
    if (blockMenu.hidden || blockMenu.contains(event.target) || blockHandle?.contains(event.target)) return
    closeBlockMenu()
  }, true)
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !blockMenu.hidden) {
      event.preventDefault()
      closeBlockMenu()
    }
  }, true)
  return blockMenu
}

function closeBlockMenu() {
  if (blockMenu) blockMenu.hidden = true
  blockHandleGrip?.setAttribute('aria-expanded', 'false')
}

function blockMenuRow(icon, title, action, { check = false } = {}) {
  const row = document.createElement('button')
  row.type = 'button'
  row.setAttribute('role', 'menuitem')
  const label = document.createElement('span')
  label.textContent = title
  // An icon's name, or a picture of its own (a colour's dot).
  row.append(typeof icon === 'string' ? slashIcon(icon, 16) : icon, label)
  if (check) {
    row.setAttribute('role', 'menuitemradio')
    const mark = slashIcon('check', 14)
    mark.dataset.role = 'check'
    row.append(mark)
  }
  row.addEventListener('click', () => {
    closeBlockMenu()
    // The block it stood by may have changed shape or place; the next move of
    // the pointer finds the block again.
    hideBlockHandle()
    action()
  })
  return row
}

/// A row that unfolds a list of rows under it (Turn into, Width, Column fit,
/// Colour), one list open at a time: `[the row, its list]`.
function blockMenuGroup(menu, target, icon, title, items) {
  const header = blockMenuRow(icon, title, () => {})
  header.setAttribute('aria-expanded', 'false')
  header.append(slashIcon('chevronDown', 10))
  const list = document.createElement('div')
  list.className = 'artifact-block-menu-kinds'
  list.hidden = true
  list.append(...items)
  header.addEventListener('click', (event) => {
    event.stopImmediatePropagation()
    const opening = list.hidden
    for (const other of menu.querySelectorAll('.artifact-block-menu-kinds')) {
      other.hidden = true
      other.previousElementSibling?.setAttribute('aria-expanded', 'false')
    }
    list.hidden = !opening
    header.setAttribute('aria-expanded', String(opening))
    menu.hidden = false
    placeBlockMenu(target)
  }, true)
  return [header, list]
}

function blockMenuSeparator() {
  const line = document.createElement('div')
  line.className = 'artifact-block-menu-separator'
  line.setAttribute('role', 'separator')
  return line
}

/// The block's words as Markdown, for Copy as Markdown.
function blockMarkdown(view, target) {
  const nodes = blockNodes(view, target)
  const serialize = editor.editor.action((ctx) => ctx.get(serializerCtx))
  const { schema } = view.state
  // A list item is serialized inside a list of its own kind.
  const holder = target.item ? [view.state.doc.resolve(target.from).parent.copy(Fragment.from(nodes))] : nodes
  // The notes its numbers cite go with it, so `[^1]` reads as a footnote
  // wherever the Markdown is pasted.
  const cited = notesForFragment(view.state.doc, Fragment.from(nodes))
  const notes = footnoteNodes(view.state.doc).definitions.filter((entry) => cited.has(entry.key)).map((entry) => entry.node)
  return markdownForStorage(serialize(schema.topNodeType.create(null, [...holder, ...notes]))).trim()
}

async function copyPlainText(text) {
  try {
    await navigator.clipboard.writeText(text)
    return
  } catch {
    // The page may not own the clipboard; the old route does.
  }
  const area = document.createElement('textarea')
  area.value = text
  area.style.position = 'fixed'
  area.style.opacity = '0'
  document.body.append(area)
  area.select()
  try { document.execCommand('copy') } finally { area.remove() }
}

/// A node and what it holds without the ids its blocks carry, so the copy is a
/// block of its own.
function withoutBlockIDs(node) {
  if (node.isText) return node
  const children = []
  node.forEach((child) => children.push(withoutBlockIDs(child)))
  const attrs = carriesBlockID(node) && node.attrs.blockID ? { ...node.attrs, blockID: '' } : node.attrs
  return node.type.create(attrs, Fragment.fromArray(children), node.marks)
}

function blockNodes(view, target) {
  return blockSiblings(view, target).map(({ node }) => node)
}

function dispatchBlockEdit(view, tr) {
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

function duplicateBlock(view, target) {
  // A footnote in the copy gets a note of its own, a copy of the original's.
  const copied = Fragment.fromArray(blockNodes(view, target).map(withoutBlockIDs))
  const copies = withFootnoteNotes(copied, notesForFragment(view.state.doc, copied))
  const tr = view.state.tr.insert(target.to, copies)
  tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(target.to + 1, tr.doc.content.size)), 1))
  dispatchBlockEdit(view, tr)
}

/// An empty line under the block, with `/` typed so the insert list is open.
function insertBelowBlock(view, target) {
  const { schema } = view.state
  const tr = view.state.tr
  let blank
  if (target.item) {
    blank = target.node.type.createAndFill({ ...target.node.attrs, blockID: undefined, checked: target.node.attrs?.checked == null ? null : false }) ?? null
    if (blank) blank = withoutBlockIDs(blank)
  } else {
    blank = schema.nodes.paragraph.create()
  }
  if (!blank) return
  tr.insert(target.to, blank)
  const caret = target.to + (target.item ? 2 : 1)
  tr.setSelection(TextSelection.create(tr.doc, Math.min(caret, tr.doc.content.size)))
  tr.insertText('/')
  dispatchBlockEdit(view, tr)
}

function deleteBlock(view, target) {
  const $from = view.state.doc.resolve(target.from)
  const parent = $from.parent
  let from = target.from
  let to = target.to
  // The last item of a list takes the list with it; the only block of a page
  // leaves an empty line to write on.
  if (target.item && parent.childCount === 1) {
    from = $from.before()
    to = from + parent.nodeSize
  }
  const tr = view.state.tr.delete(from, to)
  if (tr.doc.childCount === 0) tr.insert(0, view.state.schema.nodes.paragraph.create())
  tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(from, tr.doc.content.size)), -1))
  dispatchBlockEdit(view, tr)
}

function turnBlockInto(view, target, id) {
  const inside = Math.min(target.from + (target.item ? 2 : 1), view.state.doc.content.size)
  const tr = view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(inside), 1))
  view.dispatch(tr)
  setSelectionBlockKind(id)
}

function openBlockMenu(target) {
  const view = activeEditorView()
  if (!view || !editor) return
  const menu = ensureBlockMenu()
  const first = target.node.type.name
  const rows = []
  const canTurn = ['paragraph', 'heading', 'blockquote', 'list_item', 'bullet_list', 'ordered_list', 'code_block'].includes(first)
  if (canTurn) {
    const kinds = selectionBlockKinds.map((kind) => blockMenuRow(kind.icon, kind.title, () => turnBlockInto(view, target, kind.id)))
    rows.push(...blockMenuGroup(menu, target, 'text', 'Turn into', kinds), blockMenuSeparator())
  }
  rows.push(...blockPropertyRows(view, target, menu))
  if (first === 'table') rows.push(blockMenuRow('rowBelow', 'Insert row below', () => insertTableRowBelow(view, target)))
  rows.push(
    blockMenuRow('plus', 'Insert below', () => insertBelowBlock(view, target)),
    blockMenuRow('copy', 'Duplicate', () => duplicateBlock(view, target)),
    blockMenuRow('markdown', 'Copy as Markdown', () => { copyPlainText(blockMarkdown(view, target)) }),
  )
  if (graph.active) {
    let textblockPos = -1
    view.state.doc.nodesBetween(target.from, target.to, (node, pos) => {
      if (textblockPos >= 0) return false
      if (node.isTextblock && canTakeBlockID(view.state.doc, pos)) textblockPos = pos
      return textblockPos < 0
    })
    if (textblockPos >= 0) {
      rows.push(blockMenuRow('reference', 'Copy block reference', () => {
        const id = ensureBlockID(activeEditorView(), textblockPos)
        if (id) copyPlainText(`((${id}))`)
      }))
    }
  }
  rows.push(blockMenuSeparator(), blockMenuRow('trash', 'Delete', () => deleteBlock(view, target)))
  menu.replaceChildren(...rows)
  menu.hidden = false
  blockHandleGrip?.setAttribute('aria-expanded', 'true')
  placeBlockMenu(target)
}

function placeBlockMenu(target) {
  const menu = blockMenu
  if (!menu || menu.hidden || !blockHandle) return
  const margin = 12
  const anchor = blockHandle.getBoundingClientRect()
  const width = menu.offsetWidth
  const height = menu.offsetHeight
  const below = anchor.bottom + 4 + height <= window.innerHeight - margin
  const left = Math.min(window.innerWidth - width - margin, Math.max(margin, anchor.left))
  menu.style.left = `${Math.round(left)}px`
  menu.style.top = `${Math.round(Math.max(margin, below ? anchor.bottom + 4 : anchor.top - 4 - height))}px`
}

// ── Visualizations ──────────────────────────────────────────────────────────

const visualizationLanguage = 'visualization'
/// What a visualization's frame may do: run its own script and style, show
/// pictures and fonts it carries as data, and nothing else. No request goes
/// out, whatever the model wrote.
const visualizationPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; form-action 'none'; base-uri 'none'"
const visualizationHeightReporter = '<script>(function(){function r(){parent.postMessage({foreverlmVisualizationHeight:Math.ceil(document.body.scrollHeight)},"*")}new ResizeObserver(r).observe(document.body);addEventListener("load",r)})()<\/script>'

/// The document a visualization's frame loads: the model's HTML inside a shell
/// of this editor's own, whose first element is the policy above. The
/// document, head and body tags the model wrote, and any meta or base, are
/// taken out so nothing runs or navigates before the policy is in force.
function visualizationDocument(html) {
  const body = String(html ?? '')
    .replace(/<!doctype[^>]*>/gi, '')
    .replace(/<\/?(?:html|head|body)\b[^>]*>/gi, '')
    .replace(/<(?:meta|base)\b[^>]*>/gi, '')
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${visualizationPolicy}"><meta name="color-scheme" content="light dark"><style>html,body{margin:0;background:transparent;font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;color:CanvasText}</style></head><body>${body}${visualizationHeightReporter}</body></html>`
}

/// The frame for one visualization. It is sandboxed without `allow-same-origin`
/// so it has no way to the page, and it tells the page how tall it wants to be.
function visualizationFrame(html, { editSource = null } = {}) {
  const wrapper = document.createElement('div')
  wrapper.className = 'artifact-visualization'
  wrapper.contentEditable = 'false'
  const frame = document.createElement('iframe')
  frame.setAttribute('sandbox', 'allow-scripts')
  frame.setAttribute('referrerpolicy', 'no-referrer')
  frame.title = 'Visualization'
  frame.srcdoc = visualizationDocument(html)
  const resize = (event) => {
    if (event.source !== frame.contentWindow) return
    const height = Number(event.data?.foreverlmVisualizationHeight)
    if (Number.isFinite(height) && height > 0) frame.style.height = `${Math.round(Math.min(720, Math.max(80, height)))}px`
  }
  window.addEventListener('message', resize)
  // The listener goes with the frame: a page redrawn, or a preview put away,
  // leaves nothing listening.
  const observer = new MutationObserver(() => {
    if (wrapper.isConnected) return
    window.removeEventListener('message', resize)
    observer.disconnect()
  })
  observer.observe(document.body, { childList: true, subtree: true })
  wrapper.append(frame)
  if (editSource) {
    const bar = document.createElement('div')
    bar.className = 'artifact-visualization-bar'
    const button = document.createElement('button')
    button.type = 'button'
    button.textContent = 'Edit source'
    button.addEventListener('mousedown', (event) => event.preventDefault())
    button.addEventListener('click', editSource)
    bar.append(button)
    wrapper.append(bar)
  }
  return wrapper
}

function textHash(text) {
  let hash = 5381
  for (let index = 0; index < text.length; index += 1) hash = ((hash << 5) + hash + text.charCodeAt(index)) | 0
  return (hash >>> 0).toString(36)
}

const visualizationPlugin = $prose(() => new Plugin({
  key: new PluginKey('foreverlm-visualizations'),
  props: {
    decorations: decorationsOfDocument((state) => {
      // A host that cannot run one leaves the block as the code it is.
      if (!slashFeatures.visualize) return DecorationSet.empty
      const decorations = []
      state.doc.forEach((node, offset) => {
        if (node.type.name !== 'code_block' || node.attrs.language !== visualizationLanguage) return
        const html = node.textContent
        decorations.push(Decoration.node(offset, offset + node.nodeSize, { class: 'artifact-viz-source' }))
        decorations.push(Decoration.widget(offset, (view) => visualizationFrame(html, {
          editSource: () => {
            const source = view.nodeDOM(offset)
            source?.querySelector?.('.cm-content')?.focus()
          },
        }), { side: -1, key: `visualization:${offset}:${textHash(html)}`, ignoreSelection: true, stopEvent: () => true }))
      })
      return DecorationSet.create(state.doc, decorations)
    }, () => String(slashFeatures.visualize)),
  },
}))

// ─── The block menu ─────────────────────────────────────────────────────────
// Right-click a bullet, a block's fold chevron, or the gutter left of a block:
// Copy Block Reference, Copy Block Embed, Make Idea. Copying gives the block
// an id first when it has none, an ordinary edit of this doc.

/// The text block a right-click is about, or null.
function blockMenuTarget(event) {
  const view = foldEditorView()
  const target = event.target instanceof Element ? event.target : null
  if (!view || !target) return null
  const textblockAt = (pos) => {
    const node = view.state.doc.nodeAt(pos)
    return node?.isTextblock && canTakeBlockID(view.state.doc, pos) ? { node, pos } : null
  }
  const label = target.closest('.milkdown .editor .label-wrapper')
  if (label) {
    let found = null
    view.state.doc.descendants((node, pos) => {
      if (found) return false
      if (node.isTextblock) return false
      if (node.type.name === 'list_item' && listItemLabel(view, pos) === label) {
        found = node.firstChild?.isTextblock ? textblockAt(pos + 1) : null
        return false
      }
      return true
    })
    return found
  }
  const chevron = target.closest('.artifact-heading-fold')
  if (chevron?.dataset.foldPos) {
    const pos = Number(chevron.dataset.foldPos)
    const item = view.state.doc.nodeAt(pos)
    return item?.type.name === 'list_item' && item.firstChild?.isTextblock ? textblockAt(pos + 1) : null
  }
  if (chevron?.dataset.foldSection) {
    const heading = sectionHeadings().find(({ key }) => key === chevron.dataset.foldSection)
    if (!heading) return null
    try {
      return textblockAt(view.posAtDOM(heading.element, 0) - 1)
    } catch {
      return null
    }
  }
  // The gutter left of the writing, beside a block's first line.
  const root = view.dom
  const rect = root.getBoundingClientRect()
  const contentLeft = rect.left + (parseFloat(getComputedStyle(root).paddingLeft) || 0)
  if (event.clientX >= contentLeft || event.clientX < rect.left - 4 || event.clientY < rect.top || event.clientY > rect.bottom) return null
  const point = view.posAtCoords({ left: contentLeft + 12, top: event.clientY })
  if (!point) return null
  const $pos = view.state.doc.resolve(point.pos)
  for (let depth = $pos.depth; depth > 0; depth -= 1) {
    if ($pos.node(depth).isTextblock) return textblockAt($pos.before(depth))
  }
  return null
}

/// A block's words for an Idea's title: references read as their words and
/// title links as their titles.
function blockWords(node) {
  const text = node.textContent
  let words = ''
  let reached = 0
  for (const token of graphTokens(text)) {
    words += text.slice(reached, token.start)
    if (token.type === 'ref') {
      const block = resolvedBlock(token.blockID)
      words += block ? block.plainText : ''
    } else {
      words += token.type === 'tag' && !token.bracketed ? `#${token.title}` : token.title
    }
    reached = token.end
  }
  words += text.slice(reached)
  return (embeddedBlockID(text) ? resolvedBlock(embeddedBlockID(text))?.plainText ?? '' : words).replace(/\s+/g, ' ').trim()
}

function blockStillAt(view, target) {
  const node = view.state.doc.nodeAt(target.pos)
  return node && node.isTextblock && node.textContent === target.node.textContent ? { node, pos: target.pos } : null
}

function copyBlockMarkup(target, form) {
  const view = foldEditorView()
  const current = view ? blockStillAt(view, target) : null
  if (!current) return
  const blockID = ensureBlockID(view, current.pos)
  if (!blockID) return
  post('copyToPasteboardRequested', { text: form === 'embed' ? blockEmbed(blockID) : blockReference(blockID) })
}

document.addEventListener('contextmenu', (event) => {
  if (!graph.active) return
  const target = blockMenuTarget(event)
  if (!target) return
  event.preventDefault()
  event.stopPropagation()
  const canCopy = isEditable || Boolean(target.node.attrs.blockID)
  const words = blockWords(target.node)
  showBlockMenu(event.clientX, event.clientY, [
    { title: 'Copy Block Reference', disabled: !canCopy, run: () => copyBlockMarkup(target, 'reference') },
    { title: 'Copy Block Embed', disabled: !canCopy, run: () => copyBlockMarkup(target, 'embed') },
    {
      title: 'Make Idea',
      disabled: !words,
      run: () => post('makeIdeaRequested', target.node.attrs.blockID ? { text: words, blockID: target.node.attrs.blockID } : { text: words }),
    },
  ])
}, true)

// ─── Showing a block ────────────────────────────────────────────────────────
// After the host opens this doc to show a block (`revealBlock`), the block is
// scrolled into view and washed in the accent for a moment, the citation
// flash's look and timing (`ReaderPassageFlash`): held, then faded in two
// steps. Nothing is selected and nothing written.

const blockFlashKey = new PluginKey('foreverlm-block-flash')
let blockFlashTimers = []

const blockFlashPlugin = $prose(() => new Plugin({
  key: blockFlashKey,
  state: {
    init: () => null,
    apply(tr, flash) {
      const meta = tr.getMeta(blockFlashKey)
      if (meta !== undefined) return meta
      if (!flash || !tr.docChanged) return flash
      const mapped = tr.mapping.mapResult(flash.pos, 1)
      return mapped.deleted ? null : { ...flash, pos: mapped.pos }
    },
  },
  props: {
    decorations(state) {
      const flash = blockFlashKey.getState(state)
      const node = flash ? state.doc.nodeAt(flash.pos) : null
      if (!node) return null
      return DecorationSet.create(state.doc, [
        Decoration.node(flash.pos, flash.pos + node.nodeSize, { class: 'artifact-block-flash', 'data-flash-step': String(flash.step) }),
      ])
    },
  },
}))

function flashBlock(view, pos) {
  for (const timer of blockFlashTimers) clearTimeout(timer)
  blockFlashTimers = []
  const set = (value) => {
    const current = activeEditorView()
    if (current) current.dispatch(current.state.tr.setMeta(blockFlashKey, value).setMeta('addToHistory', false))
  }
  set({ pos, step: 0 })
  blockFlashTimers.push(setTimeout(() => {
    const flash = blockFlashKey.getState(activeEditorView()?.state)
    if (flash) set({ ...flash, step: 1 })
  }, 3200))
  blockFlashTimers.push(setTimeout(() => {
    const flash = blockFlashKey.getState(activeEditorView()?.state)
    if (flash) set({ ...flash, step: 2 })
  }, 3420))
  blockFlashTimers.push(setTimeout(() => set(null), 3640))
}

/// The text block a reveal names: by its id, else the first whose words
/// equal `plainText` (whitespace collapsed), else the first that begins with
/// them.
function findRevealTarget(doc, target) {
  const collapse = (value) => String(value ?? '').replace(/\s+/g, ' ').trim()
  const blockID = isBlockID(target?.blockID) ? target.blockID : ''
  const wanted = collapse(target?.plainText)
  let byID = null
  let equal = null
  let starting = null
  doc.descendants((node, pos) => {
    if (byID) return false
    if (!node.isTextblock) return true
    if (blockID && node.attrs?.blockID === blockID) {
      byID = { node, pos }
      return false
    }
    if (wanted) {
      const text = collapse(node.textContent)
      if (!equal && text === wanted) equal = { node, pos }
      if (!starting && text.startsWith(wanted)) starting = { node, pos }
    }
    return false
  })
  return byID ?? equal ?? starting
}

/// Open whatever folds hide a position: a folded bullet holding it, a folded
/// section above it.
function unfoldAround(view, pos) {
  const folded = outlineFoldPositions(view.state)
  const keep = folded.filter((itemPos) => {
    const node = view.state.doc.nodeAt(itemPos)
    if (!node) return false
    const hidden = outlineHiddenRange(node, itemPos)
    return !(pos >= hidden.from && pos < hidden.to)
  })
  if (keep.length !== folded.length) {
    view.dispatch(view.state.tr.setMeta(outlineFoldKey, { set: keep }).setMeta('addToHistory', false))
  }
  if (collapsedSectionKeys.size === 0) return
  const root = document.querySelector('.milkdown .editor')
  const element = root ? view.nodeDOM(view.state.doc.resolve(pos).before(1)) : null
  const children = root ? [...root.children] : []
  const elementIndex = element ? children.indexOf(element) : -1
  let opened = false
  for (const { element: heading, key } of sectionHeadings()) {
    if (!collapsedSectionKeys.has(key)) continue
    const headingIndex = children.indexOf(heading)
    if (headingIndex < 0 || elementIndex <= headingIndex) continue
    let next = heading.nextElementSibling
    let lastIndex = headingIndex
    while (next && next.tagName !== 'H1' && next.tagName !== 'H2') {
      lastIndex += 1
      next = next.nextElementSibling
    }
    if (elementIndex <= lastIndex) {
      collapsedSectionKeys.delete(key)
      opened = true
    }
  }
  if (opened) refreshSectionFolds()
}

let pendingReveal = null
let revealTimer = null

/// `revealBlock({ blockID?, plainText? })`: scroll that block into view and
/// flash it. A reveal that arrives before the doc is on the page waits for it
/// a little; one that names nothing in the doc does nothing.
function revealBlock(target) {
  pendingReveal = { target: target ?? {}, attempts: 0 }
  clearTimeout(revealTimer)
  attemptReveal()
}

function attemptReveal() {
  revealTimer = null
  const reveal = pendingReveal
  if (!reveal) return
  const view = foldEditorView()
  const found = view ? findRevealTarget(view.state.doc, reveal.target) : null
  if (!found) {
    reveal.attempts += 1
    if (reveal.attempts > (view ? 6 : 30)) {
      pendingReveal = null
      return
    }
    revealTimer = setTimeout(attemptReveal, 120)
    return
  }
  pendingReveal = null
  unfoldAround(view, found.pos + 1)
  const element = view.nodeDOM(found.pos)
  if (element instanceof Element) element.scrollIntoView({ block: 'center', behavior: 'smooth' })
  flashBlock(view, found.pos)
}

// ─── What the host hands over ───────────────────────────────────────────────

/// `setGraphContext({ docID, isDailyNote, allowsDates, blocks, titles,
/// refCounts })`: the open doc's place in the graph. Replaces what the editor
/// held; a doc opened afresh starts with nothing asked.
function setGraphContext(context) {
  const previousDocID = graph.docID
  if (!context || typeof context !== 'object') {
    graph = emptyGraph()
    fetchedBlocks = new Map()
    provisionalBlockIDs = new Set()
    missingBlockIDs = new Set()
    requestedBlockIDs = new Set()
    thisDocTitle = ''
    graphContextChanged()
    return
  }
  const docID = String(context.docID ?? '')
  const blocks = new Map()
  for (const [blockID, block] of Object.entries(context.blocks ?? {})) {
    if (isBlockID(blockID)) blocks.set(blockID, normalizedBlock(block, blockID))
  }
  const titles = new Map()
  for (const [title, page] of Object.entries(context.titles ?? {})) titles.set(normalizedTitle(title), page)
  const refCounts = new Map()
  for (const [blockID, count] of Object.entries(context.refCounts ?? {})) {
    const value = Number(count)
    if (isBlockID(blockID) && value > 0) refCounts.set(blockID, value)
  }
  graph = {
    active: true,
    docID,
    isDailyNote: Boolean(context.isDailyNote),
    allowsDates: Boolean(context.allowsDates),
    blocks,
    titles,
    refCounts,
  }
  if (docID !== previousDocID) {
    fetchedBlocks = new Map()
    missingBlockIDs = new Set()
    requestedBlockIDs = new Set()
    provisionalBlockIDs = new Set()
  } else {
    // What the editor referenced from a search reads from the host from now
    // on; one the host does not name yet is asked about again.
    for (const blockID of provisionalBlockIDs) {
      fetchedBlocks.delete(blockID)
      requestedBlockIDs.delete(blockID)
    }
    provisionalBlockIDs = new Set()
  }
  thisDocTitle = [...blocks.values()].find((block) => block.docID === docID && block.docTitle)?.docTitle ?? thisDocTitle
  graphContextChanged()
}

/// `setBlocks({ [blockID]: Block })`: the answer to `blocksRequested`. An id
/// asked about and still missing is drawn as a missing reference.
function setBlocks(map) {
  for (const [blockID, block] of Object.entries(map ?? {})) {
    if (!isBlockID(blockID) || !block) continue
    fetchedBlocks.set(blockID, normalizedBlock(block, blockID))
    missingBlockIDs.delete(blockID)
    provisionalBlockIDs.delete(blockID)
  }
  for (const blockID of requestedBlockIDs) {
    if (graphBlock(blockID) === undefined) missingBlockIDs.add(blockID)
  }
  graphContextChanged()
}

/// `setBlockReferencesFor(blockID, [Group])`: where a block of this doc is
/// referenced, for the list its count opened.
function setBlockReferencesFor(blockID, groups) {
  fillBlockReferences(String(blockID ?? ''), groups)
}

connectNotesGraph({ post, snippetOptions: graphSnippetOptions })

/// A code block's colours, the page's own: what CodeMirror draws comes from
/// the system colours and the `--code-*` variables (artifact-editor.css),
/// which hold a light and a dark value each, so code reads in both.
const pageCodeTheme = [
  CodeEditorView.theme({
    '&': { color: 'CanvasText', backgroundColor: 'transparent' },
    '.cm-content': { caretColor: 'AccentColor' },
    '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'AccentColor' },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
      backgroundColor: 'color-mix(in srgb, AccentColor 24%, transparent)',
    },
    '.cm-activeLine': { backgroundColor: 'color-mix(in srgb, CanvasText 4%, transparent)' },
    '.cm-gutters': { backgroundColor: 'transparent', color: 'color-mix(in srgb, CanvasText 38%, transparent)', border: 'none' },
    '.cm-activeLineGutter': { backgroundColor: 'transparent', color: 'color-mix(in srgb, CanvasText 70%, transparent)' },
  }),
  syntaxHighlighting(HighlightStyle.define([
    { tag: codeTags.comment, color: 'var(--code-comment)', fontStyle: 'italic' },
    { tag: [codeTags.keyword, codeTags.controlKeyword, codeTags.operatorKeyword, codeTags.modifier, codeTags.definitionKeyword], color: 'var(--code-keyword)' },
    { tag: [codeTags.string, codeTags.special(codeTags.string), codeTags.regexp, codeTags.character], color: 'var(--code-string)' },
    { tag: [codeTags.number, codeTags.bool, codeTags.null, codeTags.atom], color: 'var(--code-number)' },
    { tag: [codeTags.function(codeTags.variableName), codeTags.function(codeTags.propertyName)], color: 'var(--code-function)' },
    { tag: [codeTags.typeName, codeTags.className, codeTags.namespace], color: 'var(--code-type)' },
    { tag: [codeTags.propertyName, codeTags.attributeName, codeTags.tagName], color: 'var(--code-property)' },
    { tag: [codeTags.meta, codeTags.processingInstruction, codeTags.operator], color: 'var(--code-meta)' },
    { tag: codeTags.heading, fontWeight: 'bold' },
    { tag: codeTags.emphasis, fontStyle: 'italic' },
    { tag: codeTags.strong, fontWeight: 'bold' },
    { tag: codeTags.link, textDecoration: 'underline' },
    { tag: codeTags.invalid, color: 'var(--code-keyword)' },
  ])),
]

async function create(markdown, fontSize) {
  lastMarkdown = String(markdown ?? '')
  collapsedSectionKeys.clear()
  activeDocumentTabKey = 'document'
  userHasInteracted = false
  hasUserChanges = false
  applyingExternalMarkdown = true
  // A pooled web view keeps this script across docs; the new host has to hear
  // about this doc's references even when they match the last doc's.
  lastPostedReferenceHrefs = null
  document.documentElement.style.setProperty('--artifact-font-size', `${fontSize}px`)

  try {
    editor = new Crepe({
      root: document.getElementById('editor'),
      defaultValue: markdownForEditor(lastMarkdown),
      features: {
        [Crepe.Feature.ImageBlock]: true,
        [Crepe.Feature.TopBar]: false,
        // Formatting lives on the page's own selection bar (`ensureSelectionButton`),
        // beside Edit with AI, Comment and Chat, as on ChatGPT's Pages: select
        // words and B I S <> link and the block type are there, over the words
        // they act on. From 2026-09 it sat in the pane header instead, because
        // Crepe's bubble competed with the Chat callout for the space past the
        // selection; on 2026-10-06 the product owner asked for top bars with far fewer
        // buttons ("Quiet chrome", docs/ui-design.md), so the header lost its
        // formatting and the callout grew into one bar that holds both. Crepe's
        // toolbar stays off: two bubbles over one selection is the old clash.
        // The bar runs the same commands (`formatCommands`), `runFormatCommand`
        // stays for a host that offers them elsewhere, and ⌘B / ⌘I / ⌥⌘X / ⌘E
        // are Milkdown's keymaps, unchanged.
        [Crepe.Feature.Toolbar]: false,
        [Crepe.Feature.AI]: false,
        // Empty paragraphs are normal writing space in Notes. Crepe's default
        // block placeholder repeats "Please enter..." throughout a document.
        [Crepe.Feature.Placeholder]: false,
        // The per-line drag and add buttons clutter the page, and the slash menu
        // this feature ships is replaced by the editor's own (see "The slash
        // menu"), which also offers what the host can do: AI, pages, pictures.
        [Crepe.Feature.BlockEdit]: false,
      },
      featureConfigs: {
        // The browser's own caret. Crepe's virtual caret is a widget that
        // measures the caret's place on every transaction, which forced a
        // layout of the whole page per keystroke: about 21 ms a key on a
        // 6,500-word page against 5 to 7 ms without it. It also stood at
        // position 0 between selections, so the first block jumped, and drew
        // a second caret beside the native one.
        [Crepe.Feature.Cursor]: { virtual: false },
        // Crepe's code blocks wear One Dark in either appearance: pale words on
        // a light page and a black square behind the current line's number.
        [Crepe.Feature.CodeMirror]: { theme: pageCodeTheme },
        [Crepe.Feature.LinkTooltip]: {
          // The field takes a web address or a doc's title (see "Writing a
          // link to a doc or a Notebook"), and says so.
          inputPlaceholder: 'Paste a link, or type a page’s title',
        },
      },
    })
    editor.editor.config(withPrivateAddressPreviews)
    editor.editor.config(withPictureDescriptions)
    editor.editor.config(withBlockIDs)
    editor.editor.config(withBlockProperties)
    editor.editor.config(withFootnotes)
    editor.editor.config(withBlockPastesOnTheirOwnLine)
    editor.editor.config(withQuietTab)
    editor.editor.config(withBackspaceUnwrapping)
    editor.editor.config(withBlockShortcutsOnEnter)
    editor.editor.use(checklistShortcut)
    editor.editor.config(withDoubleDollarMath)
    // After Crepe's remark-math, whose `$` reading and writing it changes.
    editor.editor.use(dollarMathRemark)
    editor.editor.use(blockPropertiesRemark)
    editor.editor.use(joinedGroundingRemark)
    editor.editor.use(referenceCardsPlugin)
    editor.editor.use(linkPickerPlugin)
    editor.editor.use(aiEditHighlightPlugin)
    editor.editor.use(selectionPublishPlugin)
    editor.editor.use(outlineFoldPlugin)
    editor.editor.use(blockIDPlugin)
    editor.editor.use(pastedLinesPlugin)
    editor.editor.use(notesGraphPlugin)
    editor.editor.use(blockFlashPlugin)
    editor.editor.use(calloutPlugin)
    editor.editor.use(blockPropertiesPlugin)
    editor.editor.use(filePlugin)
    editor.editor.use(visualizationPlugin)
    // After the block ids' plugin: the notes it moves carry their ids, and
    // it is told so (`foreverlm-block-move`) only once it has seen the edit.
    editor.editor.use(footnotePlugin)

    editor.on((listener) => {
      listener.markdownUpdated((_ctx, markdownValue) => {
        const storageMarkdown = markdownForStorage(markdownValue)
        if (!applyingExternalMarkdown && userHasInteracted) {
          lastMarkdown = storageMarkdown
          hasUserChanges = true
          post('markdownChanged', { markdown: storageMarkdown })
        }
      })
      // The block being written in shows its references as typed; a page
      // nobody is writing in shows them all drawn.
      listener.focus(() => {
        document.body.classList.add('editing')
        editorFocused = true
        Promise.resolve().then(refreshGraphDecorations)
      })
      listener.blur(() => {
        document.body.classList.remove('editing')
        if (linkPickerState && linkPickerState.source !== 'field') hideLinkPicker()
        editorFocused = false
        Promise.resolve().then(refreshGraphDecorations)
      })
    })

    await editor.create()
    keepFootnotesOnOpen(activeEditorView())
    applyingExternalMarkdown = false
    setEditable(isEditable)
    document.body.classList.add('ready')
    convertSourceChipsToGrounding()
    // A quiet Article does not reserve tabs or heading-fold rails.
    post('ready')
  } catch (error) {
    applyingExternalMarkdown = false
    document.body.classList.add('failed')
    post('error', { message: error instanceof Error ? error.message : String(error) })
  }
}

/// Put a whole document in the editor without making it something the writer
/// can undo. A page opened in an editor that showed another starts a history
/// of its own (`fresh`): before, ⌘Z after typing on it went back past the
/// writer's words to the page shown before, and autosave then wrote that page
/// over this one. A body replaced from outside the same page (a teammate's
/// edit, a merge, its pictures arriving) stays out of the history, so ⌘Z
/// undoes only what was done here; the writer's own steps are carried
/// through it.
function replaceDocument(markdown, { fresh = false } = {}) {
  if (!editor) return
  if (fresh) {
    editor.editor.action(replaceAll(markdown, true))
    return
  }
  editor.editor.action((ctx) => {
    const view = ctx.get(editorViewCtx)
    const doc = ctx.get(parserCtx)(markdown)
    if (!doc || typeof doc === 'string') return
    const { state } = view
    view.dispatch(state.tr
      .replace(0, state.doc.content.size, new Slice(doc.content, 0, 0))
      .setMeta('addToHistory', false))
  })
}

/// `foldState` is `{ key, folds }` from a host that keeps folds: the doc's id
/// and what was folded in it when it was last open (`applyFolds`). The open
/// doc's own folds outlive a body replaced from outside — only opening
/// another doc takes the host's.
// ─── The page the host hands back ───────────────────────────────────────────
// The editor reports its text a moment after the writer stops (Milkdown's
// 200 ms listener), and the host keeps what it was last told. A host can hand
// back text the writer has already typed past: the Mac's autosave once
// replayed a save that waited behind another with the words it was asked with,
// and taking them deleted everything typed since and threw the caret. So text
// this editor reported in the last few seconds is never taken back over newer
// typing in the same page; the host is told the page as it stands instead.
// Another page opening, or text the editor never reported (a teammate's edit, a
// version restored), is taken as always.

const reportedMarkdown = []
const reportedMarkdownWindow = 10_000

function rememberReportedMarkdown(markdown) {
  const now = Date.now()
  reportedMarkdown.push({ markdown, at: now })
  while (reportedMarkdown.length > 16 || (reportedMarkdown.length && now - reportedMarkdown[0].at > reportedMarkdownWindow)) {
    reportedMarkdown.shift()
  }
}

function isReportedBefore(markdown) {
  const now = Date.now()
  return reportedMarkdown.some((entry) => entry.markdown === markdown && now - entry.at <= reportedMarkdownWindow)
}

function setMarkdown(markdown, foldState = null) {
  const value = String(markdown ?? '')
  if (!editor) return
  const opensAnotherDoc = foldState != null && foldState.key !== foldDocumentKey
  if (!opensAnotherDoc && hasUserChanges && value !== currentMarkdown() && isReportedBefore(value)) {
    post('markdownChanged', { markdown: currentMarkdown() })
    return
  }
  if (value === currentMarkdown()) {
    if (opensAnotherDoc) applyFolds(foldState.key, foldState.folds)
    // The same doc again: a pooled web view re-attached to a new host — the
    // doc closed and reopened, or opened in a second window. That host starts
    // with no answers and has just cleared the cards to their quiet form; it
    // hears which addresses the doc holds only if the editor says so again,
    // which the unchanged document would never prompt on its own. Without
    // this the cards stood without picture, metadata or check until the
    // next keystroke — a paper card looking like a bare document
    // (product owner, 2026-09-12).
    lastPostedReferenceHrefs = null
    refreshReferenceDecorations()
    return
  }

  const keptFolds = foldState == null ? null : opensAnotherDoc ? foldState.folds : foldsJSON(currentFolds())
  // Another doc: a list open over the old one has nothing to point at, and
  // neither has a preview, a reference list or a menu.
  hideLinkPicker()
  dismissedTrigger = null
  closeNotesPanels()
  hideInAppLinkTooltip(true)
  const view = activeEditorView()
  const caret = view ? captureCaretForReplacement(view) : null
  reportedMarkdown.length = 0
  applyingExternalMarkdown = true
  userHasInteracted = false
  hasUserChanges = false
  lastMarkdown = value
  collapsedSectionKeys.clear()
  activeDocumentTabKey = 'document'
  lastPostedReferenceHrefs = null
  replaceDocument(markdownForEditor(value), { fresh: opensAnotherDoc })
  keepFootnotesOnOpen(activeEditorView())
  if (caret) restoreCaretAfterReplacement(view, caret)
  if (keptFolds != null) applyFolds(foldState.key, keptFolds)
  requestAnimationFrame(() => {
    applyingExternalMarkdown = false
    refreshSectionFolds()
    convertSourceChipsToGrounding()
  })
}

// A body replaced from outside — another team member's edit arriving while
// this writer types — must not throw the caret to the top of the page and
// scroll away from the paragraph they are in. `replaceAll` builds a new
// document, so the caret is carried across as a text offset: unchanged text
// before it keeps it where it was, unchanged text after it shifts it by the
// size of the change, and a caret inside the changed passage lands at the
// start of that passage. The scroll position is put back as it was.
function captureCaretForReplacement(view) {
  const doc = view.state.doc
  const text = doc.textBetween(0, doc.content.size, '\n', '\n')
  const offset = doc.textBetween(0, view.state.selection.from, '\n', '\n').length
  const scroller = scrollContainer(view.dom)
  return { text, offset, scroller, scrollTop: scroller ? scroller.scrollTop : 0 }
}

function restoreCaretAfterReplacement(view, caret) {
  const doc = view.state.doc
  const next = doc.textBetween(0, doc.content.size, '\n', '\n')
  const limit = Math.min(caret.text.length, next.length)
  let prefix = 0
  while (prefix < limit && caret.text[prefix] === next[prefix]) prefix += 1
  let suffix = 0
  while (suffix < limit - prefix
    && caret.text[caret.text.length - 1 - suffix] === next[next.length - 1 - suffix]) suffix += 1
  let offset
  if (caret.offset <= prefix) offset = caret.offset
  else if (caret.offset >= caret.text.length - suffix) offset = caret.offset + (next.length - caret.text.length)
  else offset = prefix
  const position = positionForTextOffset(doc, Math.max(0, Math.min(offset, next.length)))
  try {
    view.dispatch(view.state.tr.setSelection(TextSelection.near(doc.resolve(position))))
  } catch {
    // An unresolvable position leaves the default selection; the scroll is
    // still put back below.
  }
  if (caret.scroller) caret.scroller.scrollTop = caret.scrollTop
}

// The document position of a character offset in the text `textBetween`
// reports with '\n' between blocks: the same walk, so the two agree.
function positionForTextOffset(doc, offset) {
  let remaining = offset
  let separated = true
  let position = null
  doc.descendants((node, nodePos) => {
    if (position != null) return false
    if (node.isText) {
      const length = node.text.length
      if (remaining <= length) {
        position = nodePos + remaining
        return false
      }
      remaining -= length
      separated = false
      return false
    }
    if (node.isBlock && !separated) {
      if (remaining === 0) {
        position = nodePos + 1
        return false
      }
      remaining -= 1
      separated = true
    }
    return true
  })
  return position ?? doc.content.size
}

function scrollContainer(element) {
  let node = element
  while (node && node !== document.body) {
    const style = getComputedStyle(node)
    if (/(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight) return node
    node = node.parentElement
  }
  return document.scrollingElement
}

function requestSave() {
  post('saveRequested', { markdown: currentMarkdown() })
}

// A team Doc reads as a page: the text is there to select and copy, the caret
// is not there to type. The host turns this on for a team copy and off for the
// private draft a member edits, and the same flag is applied again when a
// pooled web view comes back for another doc.
let isEditable = true

function setEditable(flag) {
  isEditable = Boolean(flag)
  document.body.classList.toggle('read-only', !isEditable)
  if (!isEditable) closeAIEdit()
  if (!isEditable) hideLinkPicker()
  if (!isEditable) closeSelectionBlockMenu()
  const view = activeEditorView()
  if (!view) return
  view.setProps({ editable: () => isEditable })
  // A page read as a page has no block being written in.
  refreshGraphDecorations()
}

function activeEditorView() {
  if (!editor) return null
  return editor.editor.action((ctx) => ctx.get(editorViewCtx))
}

// Crepe's Latex feature registers its node and command under these plain
// names. They are two strings, and importing them would mean reaching past the
// package's published entry points into `@milkdown/crepe/src/feature/latex`.
const mathInlineNodeName = 'math_inline'
const toggleLatexCommandName = 'ToggleLatex'

// ─── Typing math ────────────────────────────────────────────────────────────
// Crepe makes inline math the moment a second `$` is typed, so "a few $20
// copies … the $" turned the whole run into TeX (product owner, 2026-10-12:
// "don't do this when i do one dollar sign"). Typed math takes two dollar
// signs a side instead, as on Notion: `$$x^2$$` makes the math, and a price
// typed as text stays text. Crepe's rule is an input rule like any other and
// its feature does not export it, so it is recognised by what it does (it
// fires on `$x$`) and the input rules plugin is rebuilt without it, with this
// one in its place. dollar-math.js has the same line for Markdown that is read.
const doubleDollarMathPattern = /(?<![$\\])\$\$([^$]+)\$\$$/

function doubleDollarMathRule(nodeType) {
  return nodeRule(doubleDollarMathPattern, nodeType, { getAttr: (match) => ({ value: (match[1] ?? '').trim() }) })
}

function withDoubleDollarMath(ctx) {
  ctx.update(editorStateOptionsCtx, (previous) => (options) => {
    const nodeType = ctx.get(schemaCtx).nodes[mathInlineNodeName]
    if (!nodeType) return previous(options)
    const rules = ctx.get(inputRulesCtx).filter((rule) => !rule.match.test('$x$'))
    rules.push(doubleDollarMathRule(nodeType))
    const plugins = options.plugins.map((plugin) => (plugin.spec.isInputRules ? inputRules({ rules }) : plugin))
    return previous({ ...options, plugins })
  })
}

const dollarMathRemark = $remark('foreverlm-dollar-math', () => remarkMoneyIsNotMath)

/// A passage grounded one printed line at a time opens as one passage
/// (joined-grounding.js).
const joinedGroundingRemark = $remark('foreverlm-joined-grounding', () => remarkJoinedGrounding)

/// The page's formatting actions. Each entry runs exactly the command Crepe's
/// own selection toolbar ran, so formatting has moved twice — into the pane
/// header in 2026-09, onto the page's selection bar on 2026-10-06 (Quiet
/// chrome) — without changing what it does. The bar shows bold, italic,
/// strikethrough, inline code and link; inline math stays here for
/// `runFormatCommand` and is otherwise typed (`$$x$$`) or a slash-menu Equation.
const formatCommands = {
  bold: {
    isActive: (ctx, commands) => commands.call(isMarkSelectedCommand.key, strongSchema.type(ctx)),
    run: (_ctx, commands) => commands.call(toggleStrongCommand.key),
  },
  italic: {
    isActive: (ctx, commands) => commands.call(isMarkSelectedCommand.key, emphasisSchema.type(ctx)),
    run: (_ctx, commands) => commands.call(toggleEmphasisCommand.key),
  },
  strikethrough: {
    isActive: (ctx, commands) => commands.call(isMarkSelectedCommand.key, strikethroughSchema.type(ctx)),
    run: (_ctx, commands) => commands.call(toggleStrikethroughCommand.key),
  },
  code: {
    isActive: (ctx, commands) => commands.call(isMarkSelectedCommand.key, inlineCodeSchema.type(ctx)),
    run: (_ctx, commands) => commands.call(toggleInlineCodeCommand.key),
  },
  math: {
    isActive: (ctx, commands) => {
      const nodeType = ctx.get(schemaCtx).nodes[mathInlineNodeName]
      return nodeType ? commands.call(isNodeSelectedCommand.key, nodeType) : false
    },
    run: (_ctx, commands) => commands.call(toggleLatexCommandName),
  },
  link: {
    // Milkdown's own toggle (`toggleLinkCommand`), minus the links a writer
    // cannot see. A passage's attached sources ride an invisible link mark
    // (`foreverlm://grounding/…`), which the stock toggle reads as a link: the
    // button lit on every grounded passage, and one press stripped the mark,
    // detaching every source the passage stands on. Here only a visible link
    // lights the button or is removed by it.
    isActive: (ctx) => visibleLinkMarks(ctx.get(editorViewCtx).state).length > 0,
    run: (ctx) => {
      const view = ctx.get(editorViewCtx)
      const { from, to } = view.state.selection
      const visible = visibleLinkMarks(view.state)
      if (visible.length === 0) {
        ctx.get(linkTooltipAPI.key).addLink(from, to)
        return true
      }
      const tr = view.state.tr
      for (const mark of visible) tr.removeMark(from, to, mark)
      view.dispatch(tr)
      return true
    },
    // Milkdown renders this tooltip's URL field a frame after the command runs.
    // A press on the selection bar keeps focus in the prose and Milkdown moves
    // it to the field itself, but a press from host chrome (a menu-bar item)
    // leaves first responder elsewhere and would strand the writer without it.
    focusFieldSelector: '.milkdown-link-edit input',
  },
}

/// The links in the selection a writer can see — web addresses, pages,
/// notebooks, source chips — without the grounding marks attached sources ride.
function visibleLinkMarks(state) {
  const { from, to } = state.selection
  const link = state.schema.marks.link
  const marks = []
  if (!link || !(to > from)) return marks
  state.doc.nodesBetween(from, to, (node) => {
    if (!node.isText) return true
    for (const mark of node.marks) {
      if (mark.type !== link || groundingSourceIDs(mark.attrs.href).length > 0) continue
      if (!marks.some((known) => known.eq(mark))) marks.push(mark)
    }
    return true
  })
  return marks
}

/// Which of those actions the selection currently sits inside, so the selection
/// bar lights its buttons (and `selectionChanged` tells the host, as `formats`).
function activeFormats() {
  if (!editor) return []
  try {
    return editor.editor.action((ctx) => {
      const commands = ctx.get(commandsCtx)
      return Object.entries(formatCommands)
        .filter(([, command]) => {
          try {
            return command.isActive(ctx, commands) === true
          } catch {
            return false
          }
        })
        .map(([name]) => name)
    })
  } catch {
    return []
  }
}

/// Run one formatting action: for the selection bar's buttons, and for a host
/// that offers formatting elsewhere (a menu bar). A press from host chrome
/// leaves the document without first responder — ProseMirror still holds the
/// selection in its own state, which is what these commands read, and focus
/// returns to the writing surface afterwards.
function runFormatCommand(name) {
  const command = formatCommands[name]
  const view = activeEditorView()
  if (!command || !view) return

  // Formatting is the writer's own edit. Without this the markdown listener
  // reads the resulting transaction as an external load and the change is
  // never saved.
  userHasInteracted = true
  try {
    editor.editor.action((ctx) => command.run(ctx, ctx.get(commandsCtx)))
  } catch (error) {
    post('error', { message: error instanceof Error ? error.message : String(error) })
    return
  }
  // A press on host chrome landed outside the document, so focus has to come
  // back here or the next keystroke goes nowhere.
  view.focus()
  // Link then hands it on: the tooltip renders its URL field a frame later, and
  // that field, not the prose, is what the writer means to type into next.
  if (command.focusFieldSelector) {
    requestAnimationFrame(() => {
      const field = document.querySelector(command.focusFieldSelector)
      if (field instanceof HTMLElement) field.focus()
    })
  }
  requestAnimationFrame(publishSelection)
}

// ─── The selection bar ──────────────────────────────────────────────────────
// Selecting words shows one compact bar over them, in the order ChatGPT's Pages
// draws its own (product owner, 2026-10-06: "learn from chatgpt, because there is
// often way less"): what the passage stands on, Edit with AI, the marks (bold,
// italic, strikethrough, inline code, link), the block type, then Comment and
// Chat, and Idea where the host keeps the notes graph. Formatting came here
// from the pane header under the Quiet chrome rule (docs/ui-design.md): a top
// bar holds only what its pane cannot do without, and formatting acts on a
// selection, so it is reached on one. No underline: Markdown has none, and the
// page's body is Markdown (an `<u>` tag would be an HTML node on every other
// client).

let selectionSourcesButton = null
let selectionIdeaButton = null
let selectionAIGroup = null
let selectionFormatGroup = null
let selectionBlockGroup = null
let selectionBlockButton = null
let selectionBlockLabel = null
let selectionBlockMenu = null
/// The passage the type menu was opened on; a different selection closes it.
let selectionBlockMenuRange = null
/// The passage Comment, Chat or Idea was pressed on. The pane that opens takes
/// the passage with it, so the bar stays away until the selection changes; the
/// pointerup of that very press would otherwise bring it straight back.
let selectionBarDismissedRange = null
const selectionFormatButtons = new Map()

/// The marks on the bar, each named with the keystroke Milkdown binds to it.
/// Link has no keystroke: ⌘K is the app's Open Chat.
const selectionFormatItems = [
  { name: 'bold', title: 'Bold', shortcut: '⌘B', keys: 'Meta+B' },
  { name: 'italic', title: 'Italic', shortcut: '⌘I', keys: 'Meta+I' },
  { name: 'strikethrough', title: 'Strikethrough', shortcut: '⌥⌘X', keys: 'Alt+Meta+X' },
  { name: 'code', title: 'Inline code', shortcut: '⌘E', keys: 'Meta+E' },
  { name: 'link', title: 'Link' },
]

/// What the type menu turns a block into, in the menu's order. Each runs the
/// slash menu's own command (`slashBlockCommands`), so a heading made here is
/// the heading `/h1` makes.
const selectionBlockKinds = [
  { id: 'text', title: 'Text', icon: 'text' },
  { id: 'h1', title: 'Heading 1', icon: 'h1' },
  { id: 'h2', title: 'Heading 2', icon: 'h2' },
  { id: 'h3', title: 'Heading 3', icon: 'h3' },
  { id: 'bullet', title: 'Bulleted list', icon: 'bullet' },
  { id: 'numbered', title: 'Numbered list', icon: 'numbered' },
  { id: 'todo', title: 'Checklist', icon: 'todo' },
  { id: 'quote', title: 'Quote', icon: 'quote' },
  { id: 'code', title: 'Code block', icon: 'code' },
]
const selectionListKinds = new Set(['bullet', 'numbered', 'todo'])

function selectionBarGroup(name, ...children) {
  const group = document.createElement('div')
  group.className = 'artifact-selection-group'
  group.dataset.group = name
  group.append(...children)
  return group
}

/// A bar button: it never takes focus from the prose (the selection is what it
/// acts on) and does nothing once the selection is gone.
function selectionBarButton(role, title, onPress) {
  const button = document.createElement('button')
  button.type = 'button'
  button.dataset.role = role
  if (title) button.title = title
  button.addEventListener('pointerdown', (event) => event.preventDefault())
  button.addEventListener('click', () => {
    if (!currentSelection?.text) return
    onPress(button)
  })
  return button
}

function ensureSelectionButton() {
  if (selectionButton) return selectionButton
  selectionButton = document.createElement('div')
  selectionButton.className = 'artifact-selection-assistant'
  selectionButton.setAttribute('role', 'toolbar')
  selectionButton.setAttribute('aria-label', 'Selection')
  // What the passage stands on. The prose carries no marker, so this is where a
  // writer sees and edits the attachment — the count is the only visible sign
  // that a sentence is grounded at all.
  selectionSourcesButton = selectionBarButton('sources', '', () => {
    post('groundingRequested', {
      from: currentSelection.from,
      to: currentSelection.to,
      selected: currentSelection.text,
      sourceIDs: groundedSourceIDs(currentSelection.from, currentSelection.to),
    })
  })
  // The AI edits this passage on the writer's instruction; the proposal is
  // shown before anything is written (see `openAIEdit`).
  const aiEditButton = selectionBarButton('ai', 'Ask the AI to change this passage', () => openAIEdit())
  aiEditButton.textContent = 'Edit with AI'
  selectionAIGroup = selectionBarGroup('ai', aiEditButton)

  // The marks, lit while the selection carries them (`activeFormats`).
  const formatButtons = selectionFormatItems.map((item) => {
    const label = item.shortcut ? `${item.title} (${item.shortcut})` : item.title
    const button = selectionBarButton('format', label, () => runFormatCommand(item.name))
    button.dataset.format = item.name
    button.setAttribute('aria-label', item.title)
    button.setAttribute('aria-pressed', 'false')
    if (item.keys) button.setAttribute('aria-keyshortcuts', item.keys)
    button.append(slashIcon(item.name, 15))
    selectionFormatButtons.set(item.name, button)
    return button
  })
  selectionFormatGroup = selectionBarGroup('format', ...formatButtons)

  // The block the selection is in, named; a press lists what it can become.
  selectionBlockButton = selectionBarButton('block', 'Turn into', () => toggleSelectionBlockMenu())
  selectionBlockButton.setAttribute('aria-haspopup', 'menu')
  selectionBlockButton.setAttribute('aria-expanded', 'false')
  selectionBlockLabel = document.createElement('span')
  selectionBlockLabel.textContent = 'Text'
  selectionBlockButton.append(selectionBlockLabel, slashIcon('chevronDown', 10))
  selectionBlockGroup = selectionBarGroup('block', selectionBlockButton)

  const comment = selectionBarButton('comment', '', () => {
    post('commentRequested', {
      selected: currentSelection.text,
      from: currentSelection.from,
      to: currentSelection.to,
      ...currentSectionContext(),
    })
    // The pane that opens takes the passage with it; the bar has done its
    // job and would otherwise linger over the page (see `requestChat`).
    dismissSelectionBar()
  })
  comment.textContent = 'Comment'
  const chat = selectionBarButton('chat', 'Chat about selection (⌘↩)', () => {
    requestChat()
    dismissSelectionBar()
  })
  chat.textContent = 'Chat'
  chat.setAttribute('aria-keyshortcuts', 'Meta+Enter')
  // Make Idea from the passage: the host makes an Idea titled with the words,
  // linked to this doc. Only a host that keeps the notes graph answers it,
  // so the button shows only for one (`publishSelection`).
  selectionIdeaButton = selectionBarButton('idea', 'Make an Idea from this passage', () => {
    post('makeIdeaRequested', { text: currentSelection.text })
    dismissSelectionBar()
  })
  selectionIdeaButton.textContent = 'Idea'
  selectionIdeaButton.hidden = true

  selectionButton.append(
    selectionBarGroup('sources', selectionSourcesButton),
    selectionAIGroup,
    selectionFormatGroup,
    selectionBlockGroup,
    selectionBarGroup('talk', comment, chat, selectionIdeaButton),
  )
  selectionButton.hidden = true
  document.body.append(selectionButton)
  return selectionButton
}

function hideSelectionBar() {
  if (selectionButton) selectionButton.hidden = true
  closeSelectionBlockMenu()
}

function dismissSelectionBar() {
  if (currentSelection) selectionBarDismissedRange = { from: currentSelection.from, to: currentSelection.to }
  hideSelectionBar()
}

/// Which of `selectionBlockKinds` the block at the start of the selection is:
/// its own type for a heading or a code block, else the nearest list or quote
/// around it, else text. A heading below level 3 is none of them (`null`).
function selectionBlockKind(state) {
  const { $from } = state.selection
  const textblock = $from.parent
  if (textblock.type.name === 'code_block') return 'code'
  if (textblock.type.name === 'heading') {
    const level = textblock.attrs?.level ?? 1
    return level <= 3 ? `h${level}` : null
  }
  for (let depth = $from.depth - 1; depth > 0; depth -= 1) {
    const node = $from.node(depth)
    switch (node.type.name) {
      case 'list_item':
        if (node.attrs?.checked != null) return 'todo'
        break
      case 'bullet_list': return 'bullet'
      case 'ordered_list': return 'numbered'
      case 'blockquote': return 'quote'
      default: break
    }
  }
  return 'text'
}

/// A table cell holds one paragraph; nothing on the type menu fits in one.
function selectionInTable(state) {
  const { $from } = state.selection
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    if ($from.node(depth).type.name.startsWith('table')) return true
  }
  return false
}

function selectionBlockKindTitle(kind) {
  if (kind == null) return 'Heading'
  return selectionBlockKinds.find((entry) => entry.id === kind)?.title ?? 'Text'
}

function ensureSelectionBlockMenu() {
  if (selectionBlockMenu) return selectionBlockMenu
  selectionBlockMenu = document.createElement('div')
  selectionBlockMenu.className = 'artifact-selection-block-menu'
  selectionBlockMenu.setAttribute('role', 'menu')
  selectionBlockMenu.setAttribute('aria-label', 'Turn into')
  for (const kind of selectionBlockKinds) {
    const row = document.createElement('button')
    row.type = 'button'
    row.dataset.kind = kind.id
    row.setAttribute('role', 'menuitemradio')
    row.setAttribute('aria-checked', 'false')
    const title = document.createElement('span')
    title.textContent = kind.title
    const check = slashIcon('check', 14)
    check.dataset.role = 'check'
    row.append(slashIcon(kind.icon, 16), title, check)
    row.addEventListener('pointerdown', (event) => event.preventDefault())
    row.addEventListener('click', () => {
      closeSelectionBlockMenu()
      setSelectionBlockKind(kind.id)
    })
    selectionBlockMenu.append(row)
  }
  selectionBlockMenu.hidden = true
  document.body.append(selectionBlockMenu)
  return selectionBlockMenu
}

function toggleSelectionBlockMenu() {
  if (selectionBlockMenu && !selectionBlockMenu.hidden) {
    closeSelectionBlockMenu()
    return
  }
  const view = activeEditorView()
  if (!view || !currentSelection?.text) return
  const menu = ensureSelectionBlockMenu()
  selectionBlockMenuRange = { from: currentSelection.from, to: currentSelection.to }
  refreshSelectionBlockMenu(view)
  menu.hidden = false
  selectionBlockButton?.setAttribute('aria-expanded', 'true')
  positionSelectionBlockMenu()
}

function closeSelectionBlockMenu() {
  selectionBlockMenuRange = null
  if (selectionBlockMenu) selectionBlockMenu.hidden = true
  selectionBlockButton?.setAttribute('aria-expanded', 'false')
}

function refreshSelectionBlockMenu(view) {
  if (!selectionBlockMenu) return
  const kind = selectionBlockKind(view.state)
  for (const row of selectionBlockMenu.children) {
    row.setAttribute('aria-checked', String(row.dataset.kind === kind))
  }
}

/// Under the type button, opening away from the passage: up when the bar sits
/// above the words and there is room, down otherwise, and never off the page.
function positionSelectionBlockMenu() {
  if (!selectionBlockMenu || selectionBlockMenu.hidden || !selectionBlockButton || !selectionButton) return
  const margin = 12
  const gap = 4
  const anchor = selectionBlockButton.getBoundingClientRect()
  const bar = selectionButton.getBoundingClientRect()
  const width = selectionBlockMenu.offsetWidth
  const height = selectionBlockMenu.offsetHeight
  const roomAbove = bar.top - gap - height >= margin
  const roomBelow = bar.bottom + gap + height <= window.innerHeight - margin
  const opensUp = selectionButton.dataset.placement === 'above' ? (roomAbove || !roomBelow) : (!roomBelow && roomAbove)
  const top = opensUp ? bar.top - gap - height : bar.bottom + gap
  const left = Math.min(window.innerWidth - width - margin, Math.max(margin, anchor.left))
  selectionBlockMenu.style.left = `${Math.round(left)}px`
  selectionBlockMenu.style.top = `${Math.round(Math.max(margin, top))}px`
}

/// Turn the selected blocks into `id`, the way the slash menu's row of that
/// name does. A block leaves the list or quote it is in first — a bullet
/// turned into a heading becomes a heading, not a heading inside a bullet — and
/// a list turned into another kind of list keeps its items and changes its
/// marker.
function setSelectionBlockKind(id) {
  const view = activeEditorView()
  const run = slashBlockCommands[id]
  if (!view || !run || !editor || !isEditable) return
  const current = selectionBlockKind(view.state)
  if (current === id) {
    view.focus()
    return
  }
  userHasInteracted = true
  hasUserChanges = true
  const runCommand = (command) => editor.editor.action((ctx) => command(ctx, ctx.get(commandsCtx)))
  try {
    if (selectionListKinds.has(current) && selectionListKinds.has(id)) {
      changeListKind(view, id)
    } else {
      if (selectionListKinds.has(current)) liftSelectionOutOf(view, 'list_item')
      if (current === 'quote') liftSelectionOutOf(view, 'blockquote')
      // A list or a quote holds paragraphs; a heading or code block becomes one
      // first, so its words go in rather than the block wrapped whole.
      const isTextblockKind = current === null || current === 'code' || /^h\d$/.test(current ?? '')
      if ((selectionListKinds.has(id) || id === 'quote') && isTextblockKind) runCommand(slashBlockCommands.text)
      runCommand(run)
    }
  } catch (error) {
    post('error', { message: error instanceof Error ? error.message : String(error) })
  }
  view.focus()
  requestAnimationFrame(publishSelection)
}

/// Lift the selected blocks until none of them sits inside a `typeName` node.
function liftSelectionOutOf(view, typeName) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const { $from } = view.state.selection
    let inside = false
    for (let depth = $from.depth; depth > 0; depth -= 1) {
      if ($from.node(depth).type.name === typeName) {
        inside = true
        break
      }
    }
    if (!inside) return
    const listItem = view.state.schema.nodes.list_item
    const lifted = typeName === 'list_item' && listItem
      ? liftListItem(listItem)(view.state, view.dispatch)
      : lift(view.state, view.dispatch)
    if (!lifted) return
  }
}

/// Bulleted, numbered and checklist are one list with a different marker. The
/// whole list changes, as a list's marker does in a word processor: its node
/// type, each item's label and list type (Milkdown's order plugin turns a
/// bullet list back into a numbered one while its first item still says
/// "ordered"), and the checkbox a checklist item carries.
function changeListKind(view, id) {
  const { state } = view
  const { $from } = state.selection
  const nodes = state.schema.nodes
  let depth = $from.depth
  while (depth > 0 && !['bullet_list', 'ordered_list'].includes($from.node(depth).type.name)) depth -= 1
  if (depth <= 0) return
  const list = $from.node(depth)
  const listPos = $from.before(depth)
  const ordered = id === 'numbered'
  const listType = ordered ? nodes.ordered_list : nodes.bullet_list
  const tr = state.tr
  if (list.type !== listType) {
    tr.setNodeMarkup(listPos, listType, ordered ? { order: 1, spread: list.attrs.spread } : { spread: list.attrs.spread })
  }
  list.forEach((item, offset, index) => {
    if (item.type !== nodes.list_item) return
    const attrs = {
      ...item.attrs,
      listType: ordered ? 'ordered' : 'bullet',
      label: ordered ? `${index + 1}.` : '•',
    }
    if ('checked' in item.attrs) attrs.checked = id === 'todo' ? (item.attrs.checked ?? false) : null
    tr.setNodeMarkup(listPos + 1 + offset, undefined, attrs)
  })
  view.dispatch(tr)
}

/// The stretch of writing the caret sits in: its heading plus every block down
/// to the next one. This is what the note hands Chat, so a question arrives with
/// the passage it is about rather than a bare sentence.
function currentSectionContext() {
  const empty = { sectionTitle: '', sectionText: '', sectionFrom: 0, sectionTo: 0 }
  const view = activeEditorView()
  if (!view) return empty
  const doc = view.state.doc
  if (doc.childCount === 0) return empty

  const isSectionHeading = (node) => node.type.name === 'heading' && (node.attrs?.level ?? 1) <= 2
  const caretIndex = Math.min(view.state.selection.$from.index(0), doc.childCount - 1)
  let start = 0
  let sectionTitle = ''
  for (let index = caretIndex; index >= 0; index -= 1) {
    if (!isSectionHeading(doc.child(index))) continue
    start = index
    sectionTitle = doc.child(index).textContent.trim()
    break
  }
  let end = doc.childCount
  for (let index = start + 1; index < doc.childCount; index += 1) {
    // The notes at the foot belong to no section.
    if (!isSectionHeading(doc.child(index)) && !isFootnoteDefinition(doc.child(index))) continue
    end = index
    break
  }
  const blocks = []
  let sectionFrom = 0
  let sectionTo = 0
  let position = 0
  for (let index = 0; index < doc.childCount; index += 1) {
    if (index === start) sectionFrom = position
    position += doc.child(index).nodeSize
    if (index < end) sectionTo = position
    if (index >= start && index < end) blocks.push(doc.child(index).textContent)
  }
  return {
    sectionTitle,
    sectionText: blocks.join('\n\n').trim().slice(0, 6000),
    sectionFrom,
    sectionTo,
  }
}

/// Every source cited inside a span of the document, in reading order.
///
/// A citation is a link mark, so the sources a passage stands on are exactly the
/// source addresses carried by the text between two positions — a chip that
/// names a source in the sentence, and the invisible grounding a writer attached
/// to the passage itself. This is what makes a question about a highlighted
/// passage land with that passage's sources rather than with everything the note
/// happens to cite elsewhere.
///
/// The two grains union, so a selection covering a sentence grounded on A and B
/// and a sentence grounded on C arrives carrying A, B, and C.
function citedSourceIDs(from, to) {
  const view = activeEditorView()
  if (!view || !(to > from)) return []
  const ordered = []
  const seen = new Set()
  const add = (token) => {
    if (!token || seen.has(token)) return
    seen.add(token)
    ordered.push(token)
  }
  view.state.doc.nodesBetween(from, to, (node) => {
    if (!node.isText) return
    for (const mark of node.marks) {
      if (mark.type.name !== 'link') continue
      const href = mark.attrs?.href ?? ''
      add(sourceID(href))
      for (const token of groundingSourceIDs(href)) add(token)
    }
  })
  return ordered
}

/// Only the sources attached to the passage, without the ones its chips name.
/// The attach control edits exactly this list.
function groundedSourceIDs(from, to) {
  const view = activeEditorView()
  if (!view || !(to > from)) return []
  const ordered = []
  const seen = new Set()
  view.state.doc.nodesBetween(from, to, (node) => {
    if (!node.isText) return
    for (const mark of node.marks) {
      if (mark.type.name !== 'link') continue
      for (const token of groundingSourceIDs(mark.attrs?.href ?? '')) {
        if (seen.has(token)) continue
        seen.add(token)
        ordered.push(token)
      }
    }
  })
  return ordered
}

/// The stretches of a passage that grounding may take: prose, and prose only.
///
/// One link mark has to stand for three different things, so attaching sources
/// cannot simply mark the whole selection — that would overwrite the address of
/// every source chip and web link inside it, destroying the citation. Those runs
/// keep what they carry; the prose between them takes the grounding. A chip's
/// own source still reaches Chat, because `citedSourceIDs` unions both grains.
function groundableRanges(state, from, to) {
  const ranges = []
  state.doc.nodesBetween(from, to, (node, position) => {
    if (!node.isText) return
    const start = Math.max(from, position)
    const end = Math.min(to, position + node.nodeSize)
    if (end <= start) return
    const href = String(node.marks.find((mark) => mark.type.name === 'link')?.attrs?.href ?? '')
    if (href && groundingSourceIDs(href).length === 0) return
    const previous = ranges[ranges.length - 1]
    if (previous && previous.to === start) {
      previous.to = end
      return
    }
    ranges.push({ from: start, to: end })
  })
  return ranges
}

/// Attach a list of sources to the current selection, replacing whatever it was
/// grounded on before.
///
/// Replacing rather than merging is deliberate: the attachment belongs to the
/// passage as a whole, and two overlapping lists inside one sentence would make
/// "what is this standing on" unanswerable. An empty list detaches.
function groundSelection(sourceIDs) {
  const view = activeEditorView()
  if (!view) return
  const { from, to, empty } = view.state.selection
  if (empty || !(to > from)) return
  const link = view.state.schema.marks.link
  if (!link) return

  const ordered = []
  const seen = new Set()
  for (const value of Array.isArray(sourceIDs) ? sourceIDs : []) {
    const token = String(value ?? '').trim()
    if (!token || seen.has(token)) continue
    seen.add(token)
    ordered.push(token)
  }

  const ranges = groundableRanges(view.state, from, to)
  if (ranges.length === 0) return
  const href = ordered.length ? groundingHref(ordered) : ''
  const tr = view.state.tr
  for (const range of ranges) {
    tr.removeMark(range.from, range.to, link)
    if (href) tr.addMark(range.from, range.to, link.create({ href }))
  }
  if (!tr.docChanged) return
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr)
  view.focus()
}

/// Every text block in the document, as `{ node, position, from, to }`.
function textBlocks(state) {
  const blocks = []
  state.doc.descendants((node, position) => {
    if (!node.isTextblock) return true
    blocks.push({ node, position, from: position + 1, to: position + node.nodeSize - 1 })
    // A textblock's children are inline; nothing below it is another block.
    return false
  })
  return blocks
}

/// The retired source chips inside one text block, in reading order, as
/// `{ from, to, href }` ranges.
///
/// A chip is a run of text carrying one source address, so neighbouring text
/// nodes with the same address are one chip even when a second mark — a bold
/// word inside a title — splits the run into two nodes.
function sourceChipRuns(state, block) {
  const runs = []
  let offset = block.from
  block.node.forEach((child) => {
    const from = offset
    offset += child.nodeSize
    const href = child.isText
      ? String(child.marks.find((mark) => mark.type.name === 'link')?.attrs?.href ?? '')
      : ''
    if (!href || !sourceID(href)) return
    const previous = runs[runs.length - 1]
    if (previous?.to === from && previous.href === href) {
      previous.to = offset
      return
    }
    runs.push({ from, to: offset, href })
  })
  return runs
}

/// Whether a block holds writing of its own, beyond the chips in it and the
/// punctuation that joined them into a list.
function blockHasProse(state, block, chips) {
  let text = ''
  let position = block.from
  for (const chip of chips) {
    text += state.doc.textBetween(position, chip.from)
    position = chip.to
  }
  text += state.doc.textBetween(position, block.to)
  return /[^\s,;.]/.test(text)
}

/// What a chip becomes once it is attached rather than named. A chip carrying
/// `?book=` stood for the whole book, so the grounding does too — the same
/// token the attach picker sends for a book row, which is what lets a chapter
/// imported later join what the passage stands on.
function groundingTokenForChip(href) {
  const token = sourceID(href)
  if (!token) return null
  try {
    const book = new URL(href).searchParams.get('book')?.trim()
    if (book) return `book:${book}`
  } catch {
    return token
  }
  return token
}

/// The runs of a range that grounding may take, each with what it already
/// stands on.
///
/// An ordinary web link keeps the address it carries — one link mark has to
/// stand for all three — and two differently grounded runs stay separate, so
/// attaching a source to a paragraph cannot merge what the sentences inside it
/// stood on. A retired chip is prose with a card around it, so `takeSourceChips`
/// lets the conversion ground the title it wrote into the sentence.
function groundingRuns(state, from, to, takeSourceChips = false) {
  const runs = []
  state.doc.nodesBetween(from, to, (node, position) => {
    // A line break is part of the passage it stands in, so a quote's lines
    // are one run and one link.
    if (!node.isText && !isHardBreak(node)) return
    const start = Math.max(from, position)
    const end = Math.min(to, position + node.nodeSize)
    if (end <= start) return
    const href = String(node.marks.find((mark) => mark.type.name === 'link')?.attrs?.href ?? '')
    const attached = groundingSourceIDs(href)
    if (href && attached.length === 0 && !(takeSourceChips && sourceID(href))) return
    const previous = runs[runs.length - 1]
    if (previous && previous.to === start && previous.href === href) {
      previous.to = end
      return
    }
    runs.push({ from: start, to: end, href, attached })
  })
  return runs
}

/// Add sources to what each run of prose in a range already stands on, leaving
/// the rest of its list alone.
function addGrounding(tr, state, from, to, tokens, takeSourceChips = false) {
  const link = state.schema.marks.link
  if (!link || tokens.length === 0) return
  for (const run of groundingRuns(state, from, to, takeSourceChips)) {
    const ordered = [...run.attached]
    for (const token of tokens) {
      if (!ordered.includes(token)) ordered.push(token)
    }
    if (ordered.length === run.attached.length) continue
    const mark = link.create({ href: groundingHref(ordered) })
    tr.removeMark(run.from, run.to, link)
    // The run's line breaks take the mark node by node, and before the words:
    // Milkdown's hard-break plugin strips every break in the range of a
    // transaction whose first step adds a mark, which ended the link at each
    // line of a quote.
    state.doc.nodesBetween(run.from, run.to, (node, position) => {
      if (isHardBreak(node)) tr.addNodeMark(position, mark)
    })
    tr.addMark(run.from, run.to, mark)
  }
}

function isHardBreak(node) {
  return node?.type?.name === 'hardbreak'
}

/// The same range without the whitespace at its edges, so an attached passage's
/// Markdown reads `[the prose](…)` rather than `[the prose ](…)`.
function trimmedRange(state, from, to) {
  let start = from
  let end = to
  while (start < end && /\s/.test(state.doc.textBetween(start, start + 1))) start += 1
  while (end > start && /\s/.test(state.doc.textBetween(end - 1, end))) end -= 1
  return { from: start, to: end }
}

/// The nearest block with prose of its own: the one after, then the one before.
///
/// A chip that stood alone on a line was a header for the passage under it,
/// which is why what follows is preferred to what precedes.
function nearestProseBlock(prose, index) {
  for (let next = index + 1; next < prose.length; next += 1) {
    if (prose[next]) return next
  }
  for (let previous = index - 1; previous >= 0; previous -= 1) {
    if (prose[previous]) return previous
  }
  return null
}

/// Turn every source chip a doc still carries into grounding on its prose.
///
/// A chip was the visible half of citation: a source's title written into the
/// sentence and drawn as a card there. Nothing writes one any more, because a
/// source belongs to the passage that stands on it rather than to the words of
/// the sentence — so a doc that still holds one is converted the first time it
/// opens here, and saved.
///
/// The title itself stays, as ordinary prose. A sentence that leaned on it —
/// "see X and Y for context" — still reads, and the writer can cut the words
/// they no longer want; lifting them out would have left the sentence broken in
/// a way no rewriting here could fix. The passage that held the chip takes its
/// sources, the card is gone, and what the doc stands on is unchanged.
///
/// A line holding nothing but chips is the exception: it was a header for the
/// passage beside it rather than a sentence, so the line goes and that passage
/// takes its sources. Only a top-level line — emptying a list item would leave
/// a stray bullet where the title read perfectly well.
///
/// A line that is one source link and nothing else is not a chip at all: it is
/// a source card (`referenceInBlock`), the line a dropped source writes, and it
/// stays exactly as written.
function convertSourceChipsToGrounding() {
  const view = activeEditorView()
  if (!view) return
  const { state } = view
  const blocks = textBlocks(state)
  const chips = blocks.map((block) => (referenceInBlock(state, block) ? [] : sourceChipRuns(state, block)))
  if (chips.every((runs) => runs.length === 0)) return
  const prose = blocks.map((block, index) => blockHasProse(state, block, chips[index]))

  // What each passage ends up standing on, gathered before anything is written:
  // two chip lines can name the same paragraph, and writing them one at a time
  // would leave only the last one's sources on it.
  const attachments = new Map()
  const removals = []
  for (const [index, block] of blocks.entries()) {
    if (chips[index].length === 0) continue
    const tokens = []
    for (const chip of chips[index]) {
      const token = groundingTokenForChip(chip.href)
      if (token && !tokens.includes(token)) tokens.push(token)
    }
    if (tokens.length === 0) continue

    const standalone = !prose[index] && state.doc.resolve(block.position).depth === 0
    // With no prose anywhere else to carry them, the titles stay where they are
    // and stand on themselves.
    const target = standalone ? nearestProseBlock(prose, index) : index
    const passage = target ?? index
    if (target != null && standalone) {
      removals.push({ from: block.position, to: block.position + block.node.nodeSize })
    }
    attachments.set(passage, [...(attachments.get(passage) ?? []), ...tokens])
  }

  const marks = state.tr.setMeta('addToHistory', false)
  for (const [index, tokens] of attachments) {
    const range = trimmedRange(state, blocks[index].from, blocks[index].to)
    addGrounding(marks, state, range.from, range.to, tokens, true)
  }
  if (marks.docChanged) view.dispatch(marks)

  // The deletions go in a transaction of their own, and after the marks.
  // Milkdown's hard-break plugin reads the first step of every transaction as
  // though its positions belonged to the finished document, so a mark added
  // ahead of a deletion in one transaction sends it looking for positions the
  // shortened doc no longer has. Marks move nothing, which is what leaves these
  // positions valid after that first dispatch.
  const cuts = view.state.tr.setMeta('addToHistory', false)
  for (const span of removals.sort((left, right) => right.from - left.from)) {
    cuts.delete(span.from, span.to)
  }
  if (cuts.docChanged) view.dispatch(cuts)

  if (!marks.docChanged && !cuts.docChanged) return
  // The conversion is an edit to the doc rather than a way of drawing it, so it
  // has to reach storage — otherwise every open would do it again, and the
  // editor would hold a document its file does not.
  hasUserChanges = true
  lastMarkdown = currentMarkdown()
  post('markdownChanged', { markdown: lastMarkdown })
}

// MARK: - AI edits
//
// The writer says what should change — "tighten this", "turn this into a
// list", "add a sentence on the 2024 trial" — and the host's model answers
// with revised Markdown for the passage. Nothing is written until the writer
// has read the proposal and chosen Replace or Insert below, and ⌘Z undoes
// either. The editor owns the panel and the edit so the Mac and Web Studio
// behave alike; the host owns only the model call — `aiEditRequested` goes out,
// `completeAIEdit` or `failAIEdit` comes back — the same split grounding and
// formatting use.
let aiEditPanel = null
/// The edit in progress: which passage (`inline` — a run inside one paragraph —
/// or whole blocks), what was asked, and what came back. Null while no panel
/// is open. The passage's current position lives in the highlight decoration,
/// which ProseMirror maps through every keystroke, so the doc can go on
/// changing while the model works.
let aiEdit = null
let aiEditPanelRepositionFrame = 0

const aiEditHighlightKey = new PluginKey('foreverlm-ai-edit-target')

/// The passage under edit, drawn as a wash over the words while the panel is
/// open. A meta of `{ from, to }` sets it, `null` clears it; every other
/// transaction maps it along.
const aiEditHighlightPlugin = $prose(() => new Plugin({
  key: aiEditHighlightKey,
  state: {
    init: () => DecorationSet.empty,
    apply(tr, decorations) {
      const meta = tr.getMeta(aiEditHighlightKey)
      if (meta === null) return DecorationSet.empty
      if (meta) {
        // Nothing selected (Generate, Generate image): the place the writing
        // will go is a mark with no width, which ProseMirror still maps
        // through every keystroke.
        if (!(meta.to > meta.from)) {
          return DecorationSet.create(tr.doc, [
            Decoration.widget(meta.from, () => {
              const anchor = document.createElement('span')
              anchor.className = 'artifact-ai-generate-anchor'
              return anchor
            }, { side: -1, key: 'artifact-ai-generate-anchor' }),
          ])
        }
        return DecorationSet.create(tr.doc, [
          Decoration.inline(meta.from, meta.to, { class: 'artifact-ai-edit-target' }),
        ])
      }
      return decorations.map(tr.mapping, tr.doc)
    },
  },
  props: {
    decorations: (state) => aiEditHighlightKey.getState(state),
  },
}))

/// Where the passage under edit is now, or null when it has been deleted.
function aiEditRange() {
  const view = activeEditorView()
  if (!view) return null
  const found = aiEditHighlightKey.getState(view.state)?.find() ?? []
  const first = found[0]
  if (!first) return null
  // A passage has words in it; Generate stands at a point.
  if (!(first.to > first.from) && !aiEditWritesAtCaret()) return null
  return { from: first.from, to: first.to }
}

/// Whether the open panel writes new text (or a picture) where the caret was
/// rather than changing a passage.
function aiEditWritesAtCaret() {
  return aiEdit?.mode === 'generate' || aiEdit?.mode === 'image' || aiEdit?.mode === 'visualize'
}

/// What the AI is asked to change: the highlighted text when it sits inside one
/// paragraph, the whole blocks it spans otherwise, or — with nothing selected —
/// the section the caret is in, heading included. Whole blocks let the answer
/// be a heading, a list or several paragraphs; inside a sentence the answer is
/// kept to prose so the sentence's paragraph survives.
///
/// A footnote is a page of its own here: the writer working in note 2 means
/// note 2, never the section above the notes, and blocks selected inside it are
/// the note's blocks, not the `[^2]:` line that holds them.
function aiEditTarget() {
  const view = activeEditorView()
  if (!view) return null
  const { from, to, empty } = view.state.selection
  const doc = view.state.doc
  const $from = doc.resolve(from)
  const note = footnoteAround($from)
  if (!empty && to > from) {
    const $to = doc.resolve(to)
    if ($from.sameParent($to) && $from.parent.isTextblock && $from.depth > 0) {
      return { from, to, inline: true, scope: 'selection', label: 'the selected text' }
    }
    const depth = note && footnoteAround($to)?.pos === note.pos ? note.depth + 1 : 1
    const start = $from.depth >= depth ? $from.before(depth) : from
    const end = $to.depth >= depth ? $to.after(depth) : to
    return { from: start, to: end, inline: false, scope: 'selection', label: 'the selected passage' }
  }
  if (note && note.node.content.size > 0) {
    const number = footnoteNodes(doc).definitions.findIndex((entry) => entry.pos === note.pos) + 1
    return {
      from: note.pos + 1,
      to: note.pos + note.node.nodeSize - 1,
      inline: false,
      scope: 'note',
      label: number > 0 ? `note ${number}` : 'this note',
    }
  }
  const section = currentSectionContext()
  if (!(section.sectionTo > section.sectionFrom)) return null
  return {
    from: section.sectionFrom,
    to: section.sectionTo,
    inline: false,
    scope: 'section',
    label: section.sectionTitle ? `the section “${section.sectionTitle}”` : 'this section',
  }
}

/// The footnote a position stands in, with its depth and place, or null in the
/// body of the page.
function footnoteAround($pos) {
  for (let depth = $pos.depth; depth > 0; depth -= 1) {
    const node = $pos.node(depth)
    if (isFootnoteDefinition(node)) return { node, depth, pos: $pos.before(depth) }
  }
  return null
}

/// The Markdown of a stretch of the document, in its stored form.
function markdownBetween(from, to) {
  const view = activeEditorView()
  if (!view || !editor || !(to > from)) return ''
  try {
    const serialize = editor.editor.action((ctx) => ctx.get(serializerCtx))
    return markdownForStorage(serialize(view.state.doc.cut(from, to))).trim()
  } catch {
    return ''
  }
}

/// The page on one side of a passage, as the model's context: nothing when
/// that side holds no words. The empty end of the note or list item a passage
/// closes is otherwise written as `[^1]: * <br />`, which reads as markup to
/// copy rather than as the end of the page.
function contextMarkdown(from, to) {
  const view = activeEditorView()
  if (!view || !(to > from) || !view.state.doc.textBetween(from, to, ' ', ' ').trim()) return ''
  return markdownBetween(from, to)
}

/// The passage under edit as a document of its own: a run inside a paragraph
/// is that run as one paragraph, and whole blocks are those blocks, without
/// what holds them. A cut of the page keeps every ancestor, which wrote a
/// note's words as `[^1]: * …` and had the model write the note's line back
/// around its answer, where Replace read it as a second note and found nothing
/// else to write.
function aiEditPassageContent(state, from, to, inline) {
  const $from = state.doc.resolve(from)
  if (inline) {
    const $to = state.doc.resolve(to)
    const words = $from.parent.content.cut($from.parentOffset, $to.parentOffset)
    return Fragment.from(state.schema.nodes.paragraph.create(null, words))
  }
  return $from.parent.content.cut($from.parentOffset, $from.parentOffset + (to - from))
}

/// `aiEditPassageContent` as the Markdown the page stores.
function markdownOfContent(content) {
  if (!editor || !content || content.size === 0) return ''
  try {
    const serialize = editor.editor.action((ctx) => ctx.get(serializerCtx))
    const schema = editor.editor.action((ctx) => ctx.get(schemaCtx))
    return markdownForStorage(serialize(schema.topNodeType.create(null, content))).trim()
  } catch {
    return ''
  }
}

function ensureAIEditPanel() {
  if (aiEditPanel) return aiEditPanel
  const panel = document.createElement('div')
  panel.className = 'artifact-ai-edit'
  panel.hidden = true
  panel.setAttribute('role', 'dialog')
  panel.setAttribute('aria-label', 'Edit with AI')

  const head = document.createElement('div')
  head.className = 'artifact-ai-edit-head'
  const scope = document.createElement('span')
  scope.dataset.role = 'scope'
  const close = document.createElement('button')
  close.type = 'button'
  close.dataset.action = 'close'
  close.setAttribute('aria-label', 'Close')
  close.textContent = '✕'
  close.addEventListener('click', () => closeAIEdit())
  // The ForeverLM mark chooses the model the edit runs on. It shows only once
  // the host names that model (`setAIEditModel`); a press asks the host for
  // its model menu, anchored under the mark.
  const model = document.createElement('button')
  model.type = 'button'
  model.dataset.action = 'model'
  model.hidden = true
  const mark = document.createElement('img')
  mark.src = foreverLMMarkURL
  mark.alt = ''
  model.append(mark)
  model.addEventListener('click', () => {
    const rect = model.getBoundingClientRect()
    post('aiEditModelMenuRequested', { x: rect.left, y: rect.top, width: rect.width, height: rect.height })
  })
  head.append(scope, model, close)

  const form = document.createElement('form')
  form.className = 'artifact-ai-edit-ask'
  const instruction = document.createElement('input')
  instruction.type = 'text'
  instruction.dataset.role = 'instruction'
  instruction.placeholder = 'What should change? Tighten it, add a sentence on…'
  instruction.autocomplete = 'off'
  instruction.spellcheck = true
  const ask = document.createElement('button')
  ask.type = 'submit'
  ask.dataset.action = 'ask'
  ask.textContent = 'Ask'
  const chat = document.createElement('button')
  chat.type = 'button'
  chat.dataset.action = 'chat'
  chat.textContent = 'Ask in Chat'
  chat.title = 'Ask with this page, its sources, and library search available'
  chat.addEventListener('click', () => {
    const text = instruction.value.trim()
    if (!text) {
      instruction.focus()
      return
    }
    // Chat owns questions that need the learner's sources, the rest of their
    // library or the live web. The page host attaches this page and its cited
    // sources and leaves these words in the composer for the learner to send.
    // Write/Edit keeps the small, deliberately tool-less passage model.
    post('promptRequested', { text })
    closeAIEdit()
  })
  form.append(instruction, chat, ask)
  form.addEventListener('submit', (event) => {
    event.preventDefault()
    submitAIEdit(instruction.value)
  })

  const status = document.createElement('p')
  status.className = 'artifact-ai-edit-status'
  status.dataset.role = 'status'
  status.hidden = true

  const proposal = document.createElement('div')
  proposal.className = 'artifact-ai-edit-proposal'
  proposal.dataset.role = 'proposal'
  proposal.hidden = true
  // The proposal is drawn as the page will be, links included; it is read
  // here, not followed.
  proposal.addEventListener('click', (event) => {
    if (event.target instanceof Element && event.target.closest('a')) event.preventDefault()
  })

  const actions = document.createElement('div')
  actions.className = 'artifact-ai-edit-actions'
  actions.dataset.role = 'actions'
  actions.hidden = true
  for (const [action, title, hint] of [
    ['replace', 'Replace', 'Put the proposal in place of the passage (⌘↩; ⌘Z undoes)'],
    ['insert', 'Insert below', 'Keep the passage and add the proposal after it'],
    ['retry', 'Try again', 'Ask once more with the same instruction'],
    ['discard', 'Discard', 'Close without changing the page'],
  ]) {
    const button = document.createElement('button')
    button.type = 'button'
    button.dataset.action = action
    button.textContent = title
    button.title = hint
    button.addEventListener('click', () => {
      if (action === 'replace' || action === 'insert') applyAIEdit(action)
      else if (action === 'retry') submitAIEdit(aiEdit?.instruction ?? '', { again: true })
      else closeAIEdit()
    })
    actions.append(button)
  }

  panel.append(head, form, status, proposal, actions)
  // A press inside the panel must not read as a click on the page behind it:
  // the document's pointer listeners would drop the selection bubble and the
  // drag preview, and ProseMirror would move the caret.
  panel.addEventListener('pointerdown', (event) => event.stopPropagation())
  document.body.append(panel)
  aiEditPanel = panel
  return panel
}

function aiEditElement(role) {
  return ensureAIEditPanel().querySelector(`[data-role="${role}"]`)
}

function setAIEditStatus(message, { busy = false, error = false, quiet = false } = {}) {
  const status = aiEditElement('status')
  status.textContent = message ?? ''
  status.hidden = !message
  status.dataset.busy = busy ? 'true' : 'false'
  status.dataset.error = error ? 'true' : 'false'
  status.dataset.quiet = quiet ? 'true' : 'false'
  ensureAIEditPanel().querySelector('[data-action="ask"]').disabled = busy
  ensureAIEditPanel().querySelector('[data-action="chat"]').disabled = busy
  scheduleAIEditPanelReposition()
}

/// A new edit: nothing asked yet. `aliases` are the stand-ins the model reads
/// for the page's addresses (`aliasedAddresses`), kept for the whole edit so a
/// follow-up reads the same address as the same stand-in. `asked` is the
/// passage the last request carried, which Try again asks about once more.
function newAIEdit(mode, target) {
  return {
    mode,
    inline: target.inline,
    scope: target.scope,
    label: target.label,
    requestID: null,
    instruction: '',
    proposal: null,
    asked: null,
    aliases: newAddressAliases(),
  }
}

/// Open the panel over the passage the writer means: the selection, or the
/// section the caret sits in. The host's header button and the selection
/// bubble both land here.
function openAIEdit() {
  if (!isEditable) return
  const view = activeEditorView()
  const target = aiEditTarget()
  if (!view || !target) return
  closeAIEdit()
  aiEdit = newAIEdit('edit', target)
  view.dispatch(view.state.tr.setMeta(aiEditHighlightKey, { from: target.from, to: target.to }).setMeta('addToHistory', false))
  const panel = ensureAIEditPanel()
  setAIEditPanelMode('edit')
  aiEditElement('scope').textContent = `Edit ${target.label} with AI`
  const instruction = aiEditElement('instruction')
  instruction.value = ''
  aiEditElement('proposal').hidden = true
  aiEditElement('proposal').textContent = ''
  aiEditElement('actions').hidden = true
  setAIEditStatus('')
  panel.hidden = false
  hideSelectionBar()
  positionAIEditPanel()
  instruction.focus()
}

/// What the panel says and offers for each thing it is opened for: changing a
/// passage, writing new text where the caret was (the slash menu's Generate),
/// or drawing a picture there (Generate image).
const aiEditModes = {
  edit: {
    placeholder: 'What should change? Tighten it, add a sentence on…',
    insertLabel: 'Insert below',
    insertHint: 'Keep the passage and add the proposal after it',
  },
  generate: {
    placeholder: 'Describe what you want to write',
    insertLabel: 'Insert',
    insertHint: 'Write the proposal here (⌘↩; ⌘Z undoes)',
  },
  image: {
    placeholder: 'Describe the picture',
    insertLabel: 'Insert',
    insertHint: '',
  },
  visualize: {
    placeholder: 'Describe the visualization: a chart, a calculator, a diagram',
    insertLabel: 'Insert',
    insertHint: 'Write the visualization here (⌘↩; ⌘Z undoes)',
  },
}

function setAIEditPanelMode(mode) {
  const panel = ensureAIEditPanel()
  const copy = aiEditModes[mode] ?? aiEditModes.edit
  panel.dataset.mode = mode
  aiEditElement('instruction').placeholder = copy.placeholder
  const submit = panel.querySelector('[data-action="ask"]')
  submit.textContent = { edit: 'Edit', generate: 'Write', image: 'Draw', visualize: 'Create' }[mode] ?? 'Ask'
  const chat = panel.querySelector('[data-action="chat"]')
  chat.hidden = mode === 'image' || mode === 'visualize'
  const insert = panel.querySelector('[data-action="insert"]')
  insert.textContent = copy.insertLabel
  insert.title = copy.insertHint
}

/// Open the panel at the caret to write something new there: text (Generate)
/// or a picture (`image`, Generate image). The `/` that chose it is already
/// gone. Nothing is written until the writer has read the proposal and chosen
/// Insert; a picture goes in when the host has drawn it.
function openAIGenerate({ image = false, visualize = false } = {}) {
  if (!isEditable) return
  const view = activeEditorView()
  if (!view) return
  closeAIEdit()
  const at = view.state.selection.from
  const mode = image ? 'image' : visualize ? 'visualize' : 'generate'
  aiEdit = newAIEdit(mode, { inline: false, scope: mode, label: '' })
  view.dispatch(view.state.tr.setMeta(aiEditHighlightKey, { from: at, to: at }).setMeta('addToHistory', false))
  const panel = ensureAIEditPanel()
  setAIEditPanelMode(aiEdit.mode)
  aiEditElement('scope').textContent = { image: 'Generate an image', visualize: 'Create a visualization', generate: 'Write with AI' }[mode]
  const instruction = aiEditElement('instruction')
  instruction.value = ''
  aiEditElement('proposal').hidden = true
  aiEditElement('proposal').textContent = ''
  aiEditElement('actions').hidden = true
  setAIEditStatus('')
  panel.hidden = false
  hideSelectionBar()
  positionAIEditPanel()
  instruction.focus()
}

/// The model an edit runs on, named by the host, or null where the writer
/// cannot choose one (Web Studio): the mark in the panel's head shows only
/// with a name, which its tooltip gives.
function setAIEditModel(state) {
  const button = ensureAIEditPanel().querySelector('[data-action="model"]')
  const name = typeof state?.name === 'string' ? state.name.trim() : ''
  button.hidden = !name
  button.title = name ? `${name}. Choose the model for Pages` : ''
  button.setAttribute('aria-label', name ? `Model: ${name}` : 'Model')
}

/// A model the writer picked from the mark's menu could not be used; the
/// host says why, in the panel they are looking at.
function refuseAIEditModel(message) {
  if (!aiEdit) return
  setAIEditStatus(String(message ?? ''), { error: true })
}

function closeAIEdit() {
  if (!aiEdit && (!aiEditPanel || aiEditPanel.hidden)) return
  aiEdit = null
  if (aiEditPanel) aiEditPanel.hidden = true
  const view = activeEditorView()
  if (view && (aiEditHighlightKey.getState(view.state)?.find().length ?? 0) > 0) {
    view.dispatch(view.state.tr.setMeta(aiEditHighlightKey, null).setMeta('addToHistory', false))
  }
}

/// Ask the host's model. The passage travels as Markdown with a bounded run of
/// the text either side, so the model reads the sentence in its paragraph and
/// the paragraph in its section without being handed the whole report.
///
/// An instruction typed while a proposal is showing asks for a change to that
/// proposal — "shorter", "keep the second sentence" — the way a writer follows
/// up; Try again (`again`) asks the last question about the same passage once
/// more. Every address reaches the model as its stand-in.
function submitAIEdit(instructionText, { again = false } = {}) {
  const instruction = String(instructionText ?? '').trim()
  if (!aiEdit || !instruction) return
  const view = activeEditorView()
  const range = aiEditRange()
  if (!view || !range) {
    setAIEditStatus('That passage is no longer in the page.', { error: true })
    return
  }
  const requestID = `ai-edit-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
  const passage = again && aiEdit.asked != null
    ? aiEdit.asked
    : aiEdit.proposal != null && aiEdit.mode !== 'image'
      ? aiEdit.proposal
      : aiEdit.mode === 'edit'
        ? markdownOfContent(aiEditPassageContent(view.state, range.from, range.to, aiEdit.inline))
        : ''
  aiEdit.requestID = requestID
  aiEdit.instruction = instruction
  aiEdit.asked = passage
  aiEdit.proposal = null
  aiEditElement('proposal').hidden = true
  aiEditElement('actions').hidden = true
  if (aiEdit.mode === 'image') {
    // A picture is not proposed in words: the host draws it and the editor
    // writes it where the caret was (`completeImageGeneration`).
    setAIEditStatus('Drawing…', { busy: true })
    post('imageGenerationRequested', { requestID, prompt: instruction })
    return
  }
  setAIEditStatus('Working…', { busy: true })
  const contextRange = aiEdit.mode === 'edit' ? range : generateSpan(view.state, range.from)
  const aliased = (text) => aliasedAddresses(text, aiEdit.aliases)
  post('aiEditRequested', {
    requestID,
    instruction,
    inline: aiEdit.inline,
    scope: aiEdit.scope,
    // New text has no passage: the model reads the page around the caret and
    // writes what the instruction describes for it.
    passage: aliased(passage),
    before: aliased(contextMarkdown(0, contextRange.from).slice(-1500)),
    after: aliased(contextMarkdown(contextRange.to, view.state.doc.content.size).slice(0, 1500)),
    sectionTitle: currentSectionContext().sectionTitle,
    // What the page asks of an assistant working on it.
    instructions: aliased(assistantInstructions(view.state.doc)),
  })
}

/// Where Generate writes for a caret at `pos`: over the empty top-level line
/// it was chosen on, or after the top-level block it sat in, so a list or a
/// table is never put inside a sentence. `replace` says which; the model is
/// given the page up to `from` and from `to` on.
function generateSpan(state, pos) {
  const $at = state.doc.resolve(pos)
  if ($at.depth === 1 && $at.parent.isTextblock && $at.parent.content.size === 0) {
    return { from: $at.before(), to: $at.after(), replace: true }
  }
  const after = $at.depth ? $at.after(1) : pos
  return { from: after, to: after, replace: false }
}

/// The host drew the picture asked for: it goes in where the caret was, as the
/// image `insertAttachment` writes, and the panel is done. A host that cannot
/// draw it says why through `failAIEdit`, in the panel the writer is looking at.
function completeImageGeneration(requestID, attachment) {
  if (aiEdit?.mode !== 'image' || aiEdit.requestID !== requestID) return
  const view = activeEditorView()
  const range = aiEditRange()
  if (!view || !range) {
    setAIEditStatus('That place is no longer in the page.', { error: true })
    return
  }
  const $at = view.state.doc.resolve(range.from)
  // On an empty line the picture takes the line; anywhere else it follows the
  // block it was asked for in.
  const emptyLine = $at.parent.isTextblock && $at.parent.content.size === 0
  if (!emptyLine) {
    const after = $at.depth ? $at.after(1) : range.from
    view.dispatch(view.state.tr.insert(after, view.state.schema.nodes.paragraph.create()))
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(Math.min(after + 1, view.state.doc.content.size)))))
  } else {
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(range.from))))
  }
  closeAIEdit()
  insertAttachment(attachment)
}

/// A model's answer often arrives wrapped in a code fence or with a line of
/// preamble; the passage is what is inside.
function cleanedAIEditProposal(text) {
  let value = String(text ?? '').replace(/\r\n/g, '\n').trim()
  const fenced = /^```[a-zA-Z-]*\n([\s\S]*?)\n```$/.exec(value)
  if (fenced) value = fenced[1].trim()
  return value
}

function completeAIEdit(requestID, result) {
  if (!aiEdit || aiEdit.requestID !== requestID) return
  const answer = cleanedAIEditProposal(result?.markdown ?? result)
  if (!answer) {
    setAIEditStatus('The AI returned nothing for this passage.', { error: true })
    aiEditElement('actions').hidden = false
    return
  }
  // A visualization is a program and carries no page addresses.
  const proposal = aiEdit.mode === 'visualize' ? answer : restoredAddresses(answer, aiEdit.aliases)
  aiEdit.proposal = proposal
  const box = aiEditElement('proposal')
  if (aiEdit.mode === 'visualize') {
    // The proposal is a program: it is shown running, in the same frame the
    // page will draw it in, and Insert writes its source.
    box.classList.remove('is-drawn')
    box.replaceChildren(visualizationFrame(proposal))
  } else {
    const drawn = drawnProposal(proposal)
    box.classList.toggle('is-drawn', Boolean(drawn))
    if (drawn) box.replaceChildren(drawn)
    else box.textContent = proposal
  }
  box.hidden = false
  box.scrollTop = 0
  aiEditElement('actions').hidden = false
  // The instruction asked is the line above the proposal; the field is free
  // for the next one, which changes this proposal.
  setAIEditStatus(`“${aiEdit.instruction}”`, { quiet: true })
  const instruction = aiEditElement('instruction')
  instruction.value = ''
  instruction.placeholder = aiEdit.mode === 'visualize' ? 'Ask for a change to it…' : 'Ask for a change to this…'
  instruction.focus()
  scheduleAIEditPanelReposition()
}

/// The proposal and the notes the AI wrote of its own, read as the page reads
/// Markdown: `[^1]` is the page's note 1 (Footnotes, `separatedFootnotes`), and
/// a link or picture whose address the model made up (a stand-in it was never
/// given) keeps its words and loses the link. Null when it does not parse.
function parsedProposal(markdown, state) {
  if (!editor) return null
  try {
    const parse = editor.editor.action((ctx) => ctx.get(parserCtx))
    const parsed = parse(markdownForEditor(markdown) + footnoteStandIns(state.doc))
    if (!parsed || typeof parsed === 'string') return null
    const separated = separatedFootnotes(parsed, state.doc)
    return { doc: withoutMadeUpAddresses(separated.content), notes: separated.notes }
  } catch {
    return null
  }
}

function withoutMadeUpAddresses(doc) {
  const link = doc.type.schema.marks.link
  const transform = new Transform(doc)
  const pictures = []
  doc.descendants((node, pos) => {
    if (node.isText) {
      const mark = node.marks.find((candidate) => candidate.type === link && isAddressStandIn(candidate.attrs.href))
      if (mark) transform.removeMark(pos, pos + node.nodeSize, mark)
    } else if (typeof node.attrs?.src === 'string' && isAddressStandIn(node.attrs.src)) {
      pictures.push({ from: pos, to: pos + node.nodeSize })
    }
    return true
  })
  for (const picture of pictures.reverse()) transform.delete(picture.from, picture.to)
  return transform.doc
}

/// The proposal drawn as the page will draw it, with what it changes in the
/// passage marked: new words washed, words taken out struck through
/// (`markedWordChanges`). Null when it cannot be read as Markdown, and the
/// panel shows the text as it came.
function drawnProposal(markdown) {
  const view = activeEditorView()
  if (!view) return null
  const parsed = parsedProposal(markdown, view.state)
  if (!parsed || parsed.doc.childCount === 0) return null
  const serializer = DOMSerializer.fromSchema(view.state.schema)
  const drawn = document.createElement('div')
  drawn.className = 'artifact-ai-edit-drawn'
  try {
    drawn.append(serializer.serializeFragment(parsed.doc.content, { document }))
  } catch {
    return null
  }
  const range = aiEditRange()
  if (aiEdit?.mode === 'edit' && range) {
    const passage = document.createElement('div')
    try {
      passage.append(serializer.serializeFragment(aiEditPassageContent(view.state, range.from, range.to, aiEdit.inline), { document }))
      markedWordChanges(drawn, wordsOfDOM(passage).map((word) => word.text))
    } catch {
      // Drawn without marks: what Replace writes is still exactly this.
    }
  }
  return drawn
}

function failAIEdit(requestID, message) {
  if (!aiEdit || aiEdit.requestID !== requestID) return
  setAIEditStatus(String(message ?? 'The AI could not edit this passage.'), { error: true })
  aiEditElement('actions').hidden = false
}

/// Write the proposal: over the passage, or after the block it ends in. The
/// proposal is parsed as Markdown so a list comes in as a list; inside a
/// sentence it is kept to inline prose, several paragraphs joined, so the
/// sentence's own paragraph is not split in two.
function applyAIEdit(mode) {
  const view = activeEditorView()
  if (!view || !editor || !aiEdit?.proposal) return
  const range = aiEditRange()
  if (!range) {
    setAIEditStatus('That passage is no longer in the page.', { error: true })
    return
  }
  let parsed
  // Notes the AI wrote of its own, added at the foot of the page.
  let proposedNotes = []
  // A visualization is a program, not Markdown: it is written as it came.
  if (aiEdit.mode !== 'visualize') {
    const read = parsedProposal(aiEdit.proposal, view.state)
    if (!read) {
      setAIEditStatus('The proposal could not be read as Markdown.', { error: true })
      return
    }
    parsed = read.doc
    proposedNotes = read.notes
    if (!parsed || parsed.childCount === 0) {
      setAIEditStatus('The AI returned nothing for this passage.', { error: true })
      return
    }
  }
  const { schema } = view.state
  const tr = view.state.tr
  let end
  if (aiEdit.mode === 'visualize') {
    const block = schema.nodes.code_block.create({ language: visualizationLanguage }, schema.text(aiEdit.proposal))
    const span = generateSpan(view.state, range.from)
    if (span.replace) tr.replaceWith(span.from, span.to, block)
    else tr.insert(span.from, block)
    end = span.from + block.nodeSize
  } else if (aiEdit.mode === 'generate') {
    const span = generateSpan(view.state, range.from)
    if (span.replace) tr.replaceWith(span.from, span.to, parsed.content)
    else tr.insert(span.from, parsed.content)
    end = span.from + parsed.content.size
  } else if (mode === 'replace' && aiEdit.inline) {
    // Words inside a grounded passage stay grounded: the sources a passage
    // stands on are an invisible link mark over its words, and the model's
    // words arrive without it, so they take the mark the words they replace
    // carried. A citation the model kept is a link of its own and is left alone.
    const grounding = groundingMarksIn(view.state, range.from, range.to)
    const inline = []
    const withGrounding = (node) => (
      (node.isText || isHardBreak(node)) && grounding.length && !node.marks.some((mark) => mark.type === schema.marks.link)
        ? node.mark(node.marks.concat(grounding))
        : node
    )
    parsed.forEach((block, _offset, index) => {
      if (index > 0) inline.push(withGrounding(schema.text(' ')))
      if (block.isTextblock) block.forEach((child) => inline.push(withGrounding(child)))
      else if (block.textContent) inline.push(withGrounding(schema.text(block.textContent)))
    })
    if (inline.length === 0) {
      setAIEditStatus('The AI returned nothing for this passage.', { error: true })
      return
    }
    tr.replaceWith(range.from, range.to, inline)
    end = range.from + inline.reduce((size, node) => size + node.nodeSize, 0)
  } else if (mode === 'replace') {
    tr.replaceWith(range.from, range.to, parsed.content)
    end = range.from + parsed.content.size
  } else {
    // After the block the passage ends in, inside the note when it is one.
    const $to = view.state.doc.resolve(range.to)
    const depth = (footnoteAround($to)?.depth ?? 0) + 1
    const at = $to.depth >= depth ? $to.after(depth) : range.to
    tr.insert(at, parsed.content)
    end = at + parsed.content.size
  }
  if (proposedNotes.length) tr.insert(tr.doc.content.size, proposedNotes)
  tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(end, tr.doc.content.size)), -1))
  tr.setMeta(aiEditHighlightKey, null)
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  aiEdit = null
  if (aiEditPanel) aiEditPanel.hidden = true
  view.focus()
  requestAnimationFrame(publishSelection)
}

/// The grounding mark on the first words of a span — the sources that stretch
/// of writing stands on — so text written into the span can carry it too.
function groundingMarksIn(state, from, to) {
  const link = state.schema.marks.link
  let marks = []
  state.doc.nodesBetween(from, to, (node) => {
    if (marks.length || !node.isText) return true
    marks = node.marks.filter((mark) => mark.type === link && groundingSourceIDs(mark.attrs.href).length > 0)
    return true
  })
  return marks
}

/// Under the passage, and never off the page; above it when the passage ends
/// near the bottom.
function positionAIEditPanel() {
  const view = activeEditorView()
  const panel = aiEditPanel
  if (!view || !panel || panel.hidden) return
  const range = aiEditRange()
  if (!range) return
  const margin = 12
  const start = view.coordsAtPos(range.from)
  const finish = view.coordsAtPos(range.to)
  const width = panel.offsetWidth
  const height = panel.offsetHeight
  const left = Math.min(window.innerWidth - width - margin, Math.max(margin, start.left))
  let top = finish.bottom + 8
  if (top + height > window.innerHeight - margin) top = Math.max(margin, start.top - height - 8)
  panel.style.left = `${Math.round(left)}px`
  panel.style.top = `${Math.round(Math.min(window.innerHeight - height - margin, Math.max(margin, top)))}px`
}

function scheduleAIEditPanelReposition() {
  if (aiEditPanelRepositionFrame || !aiEditPanel || aiEditPanel.hidden) return
  const schedule = document.hidden
    ? (fn) => setTimeout(fn, 0)
    : (fn) => requestAnimationFrame(fn)
  aiEditPanelRepositionFrame = schedule(() => {
    aiEditPanelRepositionFrame = 0
    positionAIEditPanel()
  })
}

function requestChat() {
  const section = currentSectionContext()
  // The passage the writer highlighted decides the grounding. Only when it
  // cites nothing does the question widen — first to the section around it, and
  // then (with an empty list, resolved on the Swift side) to the whole note.
  const selected = citedSourceIDs(currentSelection?.from ?? 0, currentSelection?.to ?? 0)
  const sourceIDs = selected.length ? selected : citedSourceIDs(section.sectionFrom, section.sectionTo)
  post('chatRequested', {
    selected: currentSelection?.text ?? '',
    sourceIDs,
    grounded: groundedSourceIDs(currentSelection?.from ?? 0, currentSelection?.to ?? 0),
    sourceScope: selected.length ? 'selection' : (sourceIDs.length ? 'section' : 'document'),
    ...section,
  })
}

/// What the host was last told of the selection, and the post of a caret
/// moving while the writer types, which waits for a pause.
let lastPostedSelection = null
let caretSelectionTimer = 0

function publishSelection() {
  const view = activeEditorView()
  const button = ensureSelectionButton()
  if (!view) {
    hideSelectionBar()
    endSourceDropPreview()
    return
  }
  const { from, to, empty } = view.state.selection
  const text = empty ? '' : view.state.doc.textBetween(from, to, '\n', '\n').trim()
  currentSelection = { from, to, text }
  const grounded = empty ? [] : groundedSourceIDs(from, to)
  const formats = activeFormats()
  const selection = {
    from,
    to,
    selected: text,
    // Both grains, unioned: what the References shelf shows while the passage is
    // selected is everything the passage stands on, named or attached.
    sourceIDs: empty ? [] : citedSourceIDs(from, to),
    grounded,
    formats,
    ...currentSectionContext(),
  }
  // A caret moving as the writer types tells the host nothing it shows at
  // once: it keeps the section (for Chat) and the formats (for the header),
  // which can wait for a pause. Posting on every keyup rebuilt the whole page
  // pane on the Mac per key. A selection, a caret leaving one, or a change of
  // formats goes at once.
  clearTimeout(caretSelectionTimer)
  const formatsKey = JSON.stringify(formats)
  if (!text && lastPostedSelection?.empty && lastPostedSelection.formatsKey === formatsKey) {
    caretSelectionTimer = setTimeout(() => post('selectionChanged', selection), 400)
  } else {
    post('selectionChanged', selection)
  }
  lastPostedSelection = { empty: !text, formatsKey }
  // Comment, Chat or Idea put the bar away for this passage only.
  const dismissed = selectionBarDismissedRange
  if (dismissed && (!text || dismissed.from !== from || dismissed.to !== to)) selectionBarDismissedRange = null
  if (!text || aiEdit || linkFieldIsOpen() || selectionBarDismissedRange) {
    // Nothing left to attach to: a hint drawn over the old highlight would
    // outlive the passage it pointed at. And while the AI panel is open the
    // passage it holds is the one being edited; a second bar over it would
    // offer the same passage twice. The Link field opens above the words, where
    // the bar stands, and is the one thing the writer is typing into.
    hideSelectionBar()
    endSourceDropPreview()
    return
  }
  // The type menu belongs to the passage it was opened on.
  if (selectionBlockMenuRange && (selectionBlockMenuRange.from !== from || selectionBlockMenuRange.to !== to)) {
    closeSelectionBlockMenu()
  }
  if (selectionSourcesButton) {
    selectionSourcesButton.textContent = grounded.length
      ? `${grounded.length} ${grounded.length === 1 ? 'source' : 'sources'}`
      : 'Add sources'
    selectionSourcesButton.title = grounded.length
      ? 'Sources this passage stands on'
      : 'Attach the sources this passage stands on'
    selectionSourcesButton.dataset.grounded = grounded.length ? 'true' : 'false'
  }
  if (selectionIdeaButton) selectionIdeaButton.hidden = !graph.active
  // A team Doc reads as a page: the passage can be discussed and stands on
  // sources, but nothing in it can be restyled or rewritten.
  if (selectionAIGroup) selectionAIGroup.hidden = !isEditable
  if (selectionFormatGroup) selectionFormatGroup.hidden = !isEditable
  const kind = selectionBlockKind(view.state)
  // Code keeps its characters as typed: no mark applies inside a code block.
  const marksAllowed = kind !== 'code'
  for (const [name, formatButton] of selectionFormatButtons) {
    formatButton.disabled = !marksAllowed
    formatButton.setAttribute('aria-pressed', String(marksAllowed && formats.includes(name)))
  }
  if (selectionBlockGroup) selectionBlockGroup.hidden = !isEditable || selectionInTable(view.state)
  if (selectionBlockLabel) selectionBlockLabel.textContent = selectionBlockKindTitle(kind)
  button.hidden = false
  positionSelectionButton(view, button)
  if (selectionBlockMenu && !selectionBlockMenu.hidden) {
    refreshSelectionBlockMenu(view)
    positionSelectionBlockMenu()
  }
}

/// In a pane too narrow for one row the groups wrap; a group that starts the
/// second row drops the hairline that separated it from the group before.
function markSelectionBarRows(bar) {
  const groups = [...bar.children].filter((group) => !group.hidden)
  for (const group of groups) group.classList.remove('artifact-selection-row-start')
  let rowTop = null
  for (const group of groups) {
    if (rowTop != null && group.offsetTop > rowTop + 2) group.classList.add('artifact-selection-row-start')
    rowTop = group.offsetTop
  }
}

/// Whether Milkdown's Link field is showing (it shows above the words).
function linkFieldIsOpen() {
  return document.querySelector('.milkdown-link-edit[data-show="true"]') != null
}

/// Above the highlight, as ChatGPT's Pages places its bar, so the words being
/// formatted stay in view under it; below the highlight when its first line is
/// too near the top of the page for the bar to fit; and never off the page.
/// Measured rather than assumed: the bar is as wide as its labels (the block
/// type is named), and a clamp that guessed at that width left it hanging off
/// the right edge whenever Chat or a shelf opened beside the doc and the page
/// narrowed under it.
function positionSelectionButton(view, button) {
  const margin = 12
  const gap = 8
  const start = view.coordsAtPos(currentSelection.from)
  const end = view.coordsAtPos(currentSelection.to)
  // Measured at the left edge: a fixed box placed further right has less room,
  // and would wrap to two rows where it fits on one.
  button.style.left = '0px'
  markSelectionBarRows(button)
  const width = button.offsetWidth
  const height = button.offsetHeight
  const above = start.top - gap - height
  const below = end.bottom + gap
  let top = above
  let placement = 'above'
  if (above < margin) {
    if (below + height <= window.innerHeight - margin) {
      top = below
      placement = 'below'
    } else {
      // A highlight taller than the page: the bar stays on screen over it.
      top = Math.max(margin, Math.min(window.innerHeight - height - margin, above))
    }
  }
  // A highlight on one line starts the bar where the words start; one across
  // lines starts it at the text's left edge rather than wherever the first
  // line's selected tail began.
  let anchorLeft = start.left
  if (end.top > start.bottom - 2) {
    const editorBox = view.dom.getBoundingClientRect()
    anchorLeft = editorBox.left + (parseFloat(getComputedStyle(view.dom).paddingLeft) || 0)
  }
  const left = Math.min(window.innerWidth - width - margin, Math.max(margin, anchorLeft - 6))
  button.dataset.placement = placement
  button.style.left = `${Math.round(left)}px`
  button.style.top = `${Math.round(top)}px`
}

let selectionButtonRepositionFrame = 0

/// The page reflows when a pane opens beside it, so the highlight moves; the
/// bar (and its type menu) follow once layout has settled rather than staying
/// where the text used to be. An occluded window draws no frames, so the next
/// turn of the run loop stands in for one.
function scheduleSelectionButtonReposition() {
  if (selectionButtonRepositionFrame || !selectionButton || selectionButton.hidden) return
  const schedule = document.hidden
    ? (fn) => setTimeout(fn, 0)
    : (fn) => requestAnimationFrame(fn)
  selectionButtonRepositionFrame = schedule(() => {
    selectionButtonRepositionFrame = 0
    const view = activeEditorView()
    if (!view || !selectionButton || selectionButton.hidden || !currentSelection?.text) return
    positionSelectionButton(view, selectionButton)
    positionSelectionBlockMenu()
  })
}

function setAttachmentURLs(values) {
  attachmentDataURLs = new Map()
  attachmentStorageURLs = new Map()
  for (const [token, dataURL] of Object.entries(values ?? {})) {
    const encoded = encodeURIComponent(String(token))
    const editorURL = `${attachmentEditorPrefix}${encoded}`
    const storageURL = `${attachmentMarkdownPrefix}${encoded}`
    attachmentDataURLs.set(editorURL, String(dataURL))
    attachmentStorageURLs.set(String(dataURL), storageURL)
  }
  if (!editor) return
  const value = currentMarkdown()
  const interacted = userHasInteracted
  const changed = hasUserChanges
  applyingExternalMarkdown = true
  replaceDocument(markdownForEditor(value))
  requestAnimationFrame(() => {
    applyingExternalMarkdown = false
    userHasInteracted = interacted
    hasUserChanges = changed
  })
}

/// One more attachment the page can draw and save: its data URL is what the
/// editor shows, its token the identity the Markdown keeps.
function registerAttachment(token, dataURL) {
  const encoded = encodeURIComponent(String(token))
  attachmentDataURLs.set(`${attachmentEditorPrefix}${encoded}`, String(dataURL))
  attachmentStorageURLs.set(String(dataURL), `${attachmentMarkdownPrefix}${encoded}`)
}

function insertAttachment(attachment) {
  const view = activeEditorView()
  const token = String(attachment?.token ?? '').trim()
  const dataURL = String(attachment?.dataURL ?? '')
  if (!view || !token || !dataURL) return
  // The picture is registered without drawing the page again: `setAttachmentURLs`
  // replaces the whole document, and the caret this picture goes in at would
  // be thrown to the end of the page.
  registerAttachment(token, dataURL)
  const image = view.state.schema.nodes.image
  if (!image) {
    post('error', { message: 'This editor cannot insert images.' })
    return
  }
  userHasInteracted = true
  hasUserChanges = true
  const node = image.create({
    src: dataURL,
    alt: String(attachment?.altText ?? 'Image'),
    title: null,
  })
  view.dispatch(view.state.tr.replaceSelectionWith(node).scrollIntoView())
  view.focus()
}

/// The host kept a file the writer chose (`fileRequested`) as one of the page's
/// attachments. It is written where the caret was as a link to it, named by the
/// file's name: `[name.pdf](foreverlm://attachment/<token>)`, on a line of its
/// own when the line was empty, which draws as a card (`filePlugin`). The page
/// holds the link; the bytes live in the attachments, which travel with it.
function insertFileAttachment(file) {
  const view = activeEditorView()
  const token = String(file?.token ?? '').trim()
  if (!view || !token) return
  const name = String(file?.name ?? '').trim() || token
  const at = view.state.selection.from
  writeInAppLink(
    { title: name, href: `${attachmentMarkdownPrefix}${encodeURIComponent(token)}` },
    at,
    at,
    { replaceText: true },
  )
}

/// A line that is one link to an attached file is drawn as a card with a
/// paperclip. Markdown keeps an ordinary link.
const filePlugin = $prose(() => new Plugin({
  key: new PluginKey('foreverlm-file-cards'),
  props: {
    decorations: decorationsOfDocument((state) => {
      const decorations = []
      state.doc.forEach((node, offset) => {
        if (node.type.name !== 'paragraph' || node.childCount !== 1 || !node.firstChild.isText) return
        const link = node.firstChild.marks.find((mark) => mark.type.name === 'link')
        if (!link || !fileAttachmentLink(link.attrs?.href)) return
        decorations.push(Decoration.node(offset, offset + node.nodeSize, { class: 'artifact-file-card' }))
      })
      return DecorationSet.create(state.doc, decorations)
    }),
  },
}))

/// Take a source dragged in — from the Sources sidebar, from a chat's Sources
/// row, from anywhere a source drags.
///
/// Where the pointer is decides what the drop means. Over prose, a source
/// dropped in a doc means this passage stands on it: over the highlighted
/// passage it is the same act as picking the source in the attach picker,
/// anywhere else on a paragraph it is that paragraph, which the drag lights up
/// before the mouse comes up, and nothing visible is written into the sentence.
/// Off the prose — in the gap between two blocks, below the last one, or on an
/// empty line — there is no passage to stand on, and the drop writes the source
/// as a card of its own where the caret showed: `[Title](foreverlm://source/<id>)`
/// on a line by itself, drawn the way the chat's Sources row draws it. An empty
/// line is the case a writer makes on purpose — a heading, a blank, and a
/// source dragged onto the blank — so the card takes that line rather than
/// leaving it above. SwiftUI supplies coordinates in this editor view's
/// top-left space, which matches ProseMirror's viewport coordinates inside the
/// WKWebView.
function dropSourcesAt(citations, x, y) {
  endSourceDropPreview()
  const target = sourceDropTarget(Number(x), Number(y))
  if (target) {
    attachSourcesToRange(citations, target.from, target.to)
    return
  }
  insertSourceCardsAt(citations, Number(x), Number(y))
}

/// Write dropped sources as cards where a drop off the prose landed: one
/// paragraph per source holding its title linked to its stored address. A book
/// row stands for its book, so its card names the book and points at the
/// chapter the drag carried.
function insertSourceCardsAt(citations, x, y) {
  const view = activeEditorView()
  if (!view) return
  const entries = []
  for (const citation of Array.isArray(citations) ? citations : []) {
    const id = String(citation?.sourceID ?? '').trim()
    if (!id || entries.some((entry) => entry.id === id)) continue
    entries.push({ id, title: String(citation?.title ?? '').trim() || 'Source' })
  }
  if (entries.length === 0) return
  const pos = linkDropPosition(x, y)
  if (pos == null) return
  const { schema } = view.state
  const linkType = schema.marks.link
  const paragraphs = entries.map((entry) => schema.nodes.paragraph.create(null, schema.text(
    entry.title,
    [linkType.create({ href: `${sourceEditorPrefix}${encodeURIComponent(entry.id)}` })]
  )))
  insertBlocksAt(view, paragraphs, pos)
}

/// Write top-level blocks into the document at a point. Between blocks the
/// position is already valid; inside any block — a paragraph, a list, an
/// image — the blocks go after the top-level block the point is in, so a card
/// never lands inside a list item or a table cell. An empty paragraph at the
/// top level is the exception: the blocks take its place, because the writer
/// aimed at that line. The caret lands at the end of the last block written.
function insertBlocksAt(view, blocks, pos) {
  const { state } = view
  const $pos = state.doc.resolve(Math.max(0, Math.min(pos, state.doc.content.size)))
  const tr = state.tr
  let at
  if ($pos.depth === 0) {
    at = $pos.pos
  } else if ($pos.depth === 1 && isBlankParagraph($pos.parent)) {
    at = $pos.before(1)
    tr.delete(at, $pos.after(1))
  } else {
    at = $pos.after(1)
  }
  let end = at
  for (const block of blocks) {
    tr.insert(end, block)
    end += block.nodeSize
  }
  tr.setSelection(TextSelection.create(tr.doc, end - 1))
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

/// What a drop at a point would attach to, or null when there is nothing: the
/// point is off the prose, or the block under it has no words. An empty line
/// is not a passage — attaching to it would write nothing and say nothing,
/// which is what a source dragged onto a blank line under a heading did until
/// 2026-09-12 — so it is answered like the gap between two blocks, and the
/// drop writes a card there.
function sourceDropTarget(x, y) {
  const view = activeEditorView()
  if (!view || !Number.isFinite(x) || !Number.isFinite(y)) return null
  if (selectionCoversPoint(x, y)) {
    const { from, to } = view.state.selection
    return { from, to }
  }
  const block = blockAtPoint(x, y)
  if (!block) return null
  const range = trimmedRange(view.state, block.from, block.to)
  return range.to > range.from ? { from: block.from, to: block.to } : null
}

/// A paragraph with no words: nothing in it, or only whitespace.
function isBlankParagraph(node) {
  if (!node || node.type.name !== 'paragraph') return false
  for (let index = 0; index < node.childCount; index += 1) {
    const child = node.child(index)
    if (!child.isText || child.text.trim() !== '') return false
  }
  return true
}

/// The text block under a point, or null when the point is not over prose.
function blockAtPoint(x, y) {
  const view = activeEditorView()
  if (!view) return null
  const point = view.posAtCoords({ left: x, top: y })
  if (!point) return null
  const $position = view.state.doc.resolve(point.pos)
  for (let depth = $position.depth; depth > 0; depth -= 1) {
    const node = $position.node(depth)
    if (!node.isTextblock) continue
    const position = $position.before(depth)
    return { node, position, from: position + 1, to: position + node.nodeSize - 1 }
  }
  return null
}

/// Add dropped sources to what a passage already stands on.
///
/// Adding rather than replacing is what separates the drag from the picker: the
/// picker shows the whole list and sends back the writer's edit of it, while a
/// drag says only "this one as well". Each differently grounded run inside the
/// passage keeps its own list — see `addGrounding`.
function attachSourcesToRange(citations, from, to) {
  const view = activeEditorView()
  if (!view || !(to > from)) return
  const tokens = groundingTokensForCitations(citations)
  if (tokens.length === 0) return
  const range = trimmedRange(view.state, from, to)
  if (!(range.to > range.from)) return
  const tr = view.state.tr
  addGrounding(tr, view.state, range.from, range.to, tokens)
  if (!tr.docChanged) return
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr)
  // The bubble's count is the writer's confirmation that the drop landed where
  // they aimed it. It is otherwise only recomputed on pointer and key release.
  requestAnimationFrame(publishSelection)
}

/// Attach sources to the highlighted passage.
///
/// A drop that landed on the pane but not on the page — the title, or the
/// source shelf under it — has no paragraph beneath the pointer, and the
/// passage the writer highlighted is the only thing it can mean.
function attachSourcesToSelection(citations) {
  const view = activeEditorView()
  if (!view) return
  const { from, to } = view.state.selection
  attachSourcesToRange(citations, from, to)
}

/// The grounding tokens a set of dragged sources stands for. A book row stands
/// for the whole book, exactly as the attach picker sends it.
function groundingTokensForCitations(citations) {
  const tokens = []
  for (const citation of Array.isArray(citations) ? citations : []) {
    const bookID = String(citation?.bookID ?? '').trim()
    const token = bookID ? `book:${bookID}` : String(citation?.sourceID ?? '').trim()
    if (token && !tokens.includes(token)) tokens.push(token)
  }
  return tokens
}

/// The rectangles a document range covers, in viewport coordinates.
///
/// Built from ProseMirror positions rather than `window.getSelection()`: a drag
/// coming from the sidebar takes first responder away from the document, and
/// the DOM selection is not something to depend on while another view holds it.
function rangeClientRects(from, to) {
  const view = activeEditorView()
  if (!view || !(to > from)) return []
  try {
    const start = view.domAtPos(from)
    const end = view.domAtPos(to)
    const range = document.createRange()
    range.setStart(start.node, start.offset)
    range.setEnd(end.node, end.offset)
    return Array.from(range.getClientRects())
      .filter((rect) => rect.width > 0.5 && rect.height > 0.5)
  } catch {
    return []
  }
}

function selectionClientRects() {
  const view = activeEditorView()
  if (!view) return []
  const { from, to, empty } = view.state.selection
  return empty ? [] : rangeClientRects(from, to)
}

function selectionCoversPoint(x, y) {
  if (!Number.isFinite(x) || !Number.isFinite(y)) return false
  return selectionClientRects().some((rect) => x >= rect.left - 2
    && x <= rect.right + 2
    && y >= rect.top - 2
    && y <= rect.bottom + 2)
}

/// Light the passage a dragged source is about to attach to — or, off the
/// prose, show the caret where its card will be written.
///
/// Attaching is invisible in the prose, so without this the drag says nothing
/// at all: the writer would let go and have to trust that the source landed on
/// the passage they aimed at rather than the paragraph beside it.
function previewSourceDrop(x, y) {
  const target = sourceDropTarget(Number(x), Number(y))
  const rects = target ? rangeClientRects(target.from, target.to) : []
  if (rects.length === 0) {
    previewLinkDrop(x, y)
    return
  }
  const layer = ensureSelectionDropLayer()
  layer.replaceChildren(...rects.map((rect) => {
    const box = document.createElement('div')
    box.className = 'artifact-selection-drop-box'
    box.style.left = `${rect.left}px`
    box.style.top = `${rect.top}px`
    box.style.width = `${rect.width}px`
    box.style.height = `${rect.height}px`
    return box
  }))
  layer.hidden = false
}

function endSourceDropPreview() {
  if (!selectionDropLayer) return
  selectionDropLayer.replaceChildren()
  selectionDropLayer.hidden = true
}

/// Where a dragged doc or Notebook would be written: the caret position under
/// the pointer, or the end of the document when the pointer is below the last
/// paragraph. Null only when there is no editor to write into.
function linkDropPosition(x, y) {
  const view = activeEditorView()
  if (!view) return null
  if (Number.isFinite(x) && Number.isFinite(y)) {
    const point = view.posAtCoords({ left: x, top: y })
    if (point) return point.pos
  }
  return view.state.doc.content.size
}

/// A dragged doc or Notebook becomes a titled link in the prose, so unlike a
/// source drop the drag has a caret to show: a thin bar where the link will be
/// written, drawn in the same layer the source highlight uses.
function previewLinkDrop(x, y) {
  const view = activeEditorView()
  const pos = linkDropPosition(Number(x), Number(y))
  if (!view || pos == null) {
    endSourceDropPreview()
    return
  }
  let coords
  try {
    coords = view.coordsAtPos(Math.min(pos, view.state.doc.content.size))
  } catch {
    endSourceDropPreview()
    return
  }
  const layer = ensureSelectionDropLayer()
  const caret = document.createElement('div')
  caret.className = 'artifact-link-drop-caret'
  caret.style.left = `${coords.left}px`
  caret.style.top = `${coords.top}px`
  caret.style.height = `${Math.max(coords.bottom - coords.top, 16)}px`
  layer.replaceChildren(caret)
  layer.hidden = false
}

/// Write links to docs or Notebooks into the prose at a point.
///
/// `links` is `[{ title, href }]` with `href` in the stored `foreverlm://`
/// form; it is translated to the editor's private address so Milkdown's link
/// mark keeps it. Inside a paragraph the links join the sentence, spaced from
/// the words either side; between blocks, or below the last one, they become a
/// paragraph of their own. The caret lands after what was written.
function insertLinksAt(links, x, y) {
  endSourceDropPreview()
  const view = activeEditorView()
  if (!view) return
  const entries = (Array.isArray(links) ? links : [])
    .map((entry) => ({ title: String(entry?.title ?? '').trim(), href: editorAddress(String(entry?.href ?? '')) }))
    .filter((entry) => entry.href && inAppLink(entry.href))
  if (entries.length === 0) return
  const pos = linkDropPosition(Number(x), Number(y))
  if (pos == null) return

  const { state } = view
  const { schema } = state
  const linkType = schema.marks.link
  const separator = () => schema.text(', ')
  const inline = []
  entries.forEach((entry, index) => {
    if (index > 0) inline.push(separator())
    const title = entry.title || (inAppLink(entry.href)?.kind === 'notebook' ? 'Notebook' : 'Page')
    inline.push(schema.text(title, [linkType.create({ href: entry.href })]))
  })

  const $pos = state.doc.resolve(Math.min(pos, state.doc.content.size))
  const tr = state.tr
  let end
  if ($pos.parent.isTextblock) {
    const before = $pos.nodeBefore?.isText ? $pos.nodeBefore.text.slice(-1) : ''
    const after = $pos.nodeAfter?.isText ? $pos.nodeAfter.text.slice(0, 1) : ''
    const content = []
    if ($pos.parentOffset > 0 && before && !/\s/.test(before)) content.push(schema.text(' '))
    content.push(...inline)
    if ($pos.parentOffset < $pos.parent.content.size && after && !/\s/.test(after)) content.push(schema.text(' '))
    tr.insert($pos.pos, content)
    end = $pos.pos + content.reduce((size, node) => size + node.nodeSize, 0)
  } else {
    const paragraph = schema.nodes.paragraph.create(null, inline)
    // Between blocks the position is already valid; inside a non-text block
    // (an image, a divider) write after it.
    const at = $pos.parent.type === schema.nodes.doc ? $pos.pos : $pos.after($pos.depth)
    tr.insert(at, paragraph)
    end = at + paragraph.nodeSize - 1
  }
  tr.setSelection(TextSelection.create(tr.doc, end))
  // As in `writeInAppLink`: typing on from the link's end is prose, not more link.
  tr.setStoredMarks([])
  userHasInteracted = true
  hasUserChanges = true
  view.dispatch(tr.scrollIntoView())
  view.focus()
  requestAnimationFrame(publishSelection)
}

function ensureSelectionDropLayer() {
  if (selectionDropLayer) return selectionDropLayer
  selectionDropLayer = document.createElement('div')
  selectionDropLayer.className = 'artifact-selection-drop-layer'
  selectionDropLayer.hidden = true
  document.body.append(selectionDropLayer)
  return selectionDropLayer
}

document.addEventListener('keydown', (event) => {
  // The selection bar's type menu is a pointer menu over the prose: Escape puts
  // it away and leaves the selection where it was.
  if (event.key === 'Escape' && selectionBlockMenu && !selectionBlockMenu.hidden) {
    event.preventDefault()
    event.stopPropagation()
    closeSelectionBlockMenu()
    return
  }
  if (aiEditPanel && !aiEditPanel.hidden && aiEditPanel.contains(event.target)) {
    // Typing an instruction is not writing in the doc: ⌘↩ must not open a
    // chat about the passage, and Escape puts the panel away.
    if (event.key === 'Escape') {
      event.preventDefault()
      closeAIEdit()
    } else if (event.metaKey && event.key === 'Enter' && aiEdit?.proposal != null) {
      // ⌘↩ takes the proposal the way its blue button does.
      event.preventDefault()
      applyAIEdit(aiEdit.mode === 'edit' ? 'replace' : 'insert')
    }
    return
  }
  if (event.metaKey && event.key === 'Enter') {
    event.preventDefault()
    requestChat()
    return
  }
  if (event.metaKey && event.key.toLowerCase() === 's') {
    event.preventDefault()
    requestSave()
    return
  }

  userHasInteracted = true
}, true)

document.addEventListener('input', () => {
  scheduleSectionFoldRefresh()
}, true)

for (const eventName of ['pointerdown', 'beforeinput', 'paste', 'drop', 'cut']) {
  document.addEventListener(eventName, () => {
    userHasInteracted = true
  }, true)
}

// A press anywhere but the type menu or the button that opened it closes it.
document.addEventListener('pointerdown', (event) => {
  if (!selectionBlockMenu || selectionBlockMenu.hidden) return
  if (selectionBlockMenu.contains(event.target) || selectionBlockButton?.contains(event.target)) return
  closeSelectionBlockMenu()
}, true)

// ─── Sources dropped through the browser ────────────────────────────────────
// On macOS an in-app drag never reaches the page: the web view claims it at
// the AppKit level and calls `dropSourcesAt` itself. In Web Studio the same
// drag is the browser's, so the page hears it here: a Sources row or a chat's
// source card carries the source ids under Web Studio's own types, and a
// dragged `foreverlm://source/<id>` link — a card in a reply — carries them as
// its address. The editor knows only ids; the host names them from its library
// and calls `dropSourcesAt` with the titles, exactly as the Mac does.
const sourceDragTypes = ['application/x-foreverlm-sources', 'application/x-foreverlm-source']

function carriesSourceDrag(dataTransfer) {
  const types = Array.from(dataTransfer?.types ?? [])
  return types.some((type) => sourceDragTypes.includes(type))
}

/// The source ids a browser drag carries, in order, or none for any other drag.
function draggedSourceIDs(dataTransfer) {
  if (!dataTransfer) return []
  const ids = []
  const add = (value) => {
    const id = String(value ?? '').trim()
    if (id && !ids.includes(id)) ids.push(id)
  }
  try {
    const many = dataTransfer.getData('application/x-foreverlm-sources')
    if (many) {
      const parsed = JSON.parse(many)
      if (Array.isArray(parsed)) parsed.forEach(add)
    }
  } catch {
    // Not JSON: the single-source type below still names the source.
  }
  add(dataTransfer.getData('application/x-foreverlm-source'))
  if (ids.length === 0) {
    for (const line of String(dataTransfer.getData('text/uri-list') || '').split(/\r?\n/)) {
      if (line.startsWith('#')) continue
      add(sourceID(line.trim()))
    }
  }
  return ids
}

document.addEventListener('dragover', (event) => {
  if (!carriesSourceDrag(event.dataTransfer)) return
  event.preventDefault()
  event.dataTransfer.dropEffect = 'copy'
  previewSourceDrop(event.clientX, event.clientY)
}, true)

document.addEventListener('dragleave', (event) => {
  // The drag left the page altogether; leaving one element for another inside
  // it fires the same event with the next element as `relatedTarget`.
  if (event.relatedTarget == null) endSourceDropPreview()
}, true)

document.addEventListener('drop', (event) => {
  const sourceIDs = draggedSourceIDs(event.dataTransfer)
  if (sourceIDs.length === 0) return
  // Ours, not ProseMirror's: without this the address would be pasted as text.
  event.preventDefault()
  event.stopPropagation()
  endSourceDropPreview()
  post('sourcesDropped', { sourceIDs, x: event.clientX, y: event.clientY })
}, true)

for (const eventName of ['pointerup', 'keyup']) {
  document.addEventListener(eventName, () => requestAnimationFrame(publishSelection), true)
}

// The selection as the editor holds it, not as it stood when the pointer went
// up: a shift-click (or a double-click) extends the selection after pointerup,
// when `selectionchange` reaches the editor, so the bar read a caret, stayed
// hidden, and the words stood selected with nothing to act on them. Any change
// of the editor's selection publishes it again, once the pointer is up (a bar
// that followed a drag would jump with every word).
let pointerIsDown = false
document.addEventListener('pointerdown', () => { pointerIsDown = true }, true)
document.addEventListener('pointerup', () => { pointerIsDown = false }, true)
let selectionPublishScheduled = false

function scheduleSelectionPublish() {
  if (selectionPublishScheduled) return
  selectionPublishScheduled = true
  const run = () => {
    selectionPublishScheduled = false
    publishSelection()
  }
  if (document.hidden) setTimeout(run, 0)
  else requestAnimationFrame(run)
}

const selectionPublishPlugin = $prose(() => new Plugin({
  view: () => ({
    update(view, previous) {
      if (pointerIsDown || previous.selection.eq(view.state.selection)) return
      scheduleSelectionPublish()
    },
  }),
}))

document.addEventListener('scroll', () => {
  hideSelectionBar()
  endSourceDropPreview()
  positionLinkPicker()
  scheduleAIEditPanelReposition()
  scheduleFoldControlsRefresh()
  // The page moved under a pointer that did not: another line may be under it.
  if (lastPointer && hoverFrame == null) hoverFrame = requestAnimationFrame(refreshHoveredFoldTarget)
}, true)

window.addEventListener('resize', () => {
  positionLinkPicker()
  scheduleSectionFoldRefresh()
  scheduleSelectionButtonReposition()
  scheduleMarginCardLayout()
  scheduleAIEditPanelReposition()
})

window.foreverLMArtifactEditor = {
  create,
  setMarkdown,
  setEditable,
  requestSave,
  dropSourcesAt,
  attachSourcesToSelection,
  previewSourceDrop,
  previewLinkDrop,
  insertLinksAt,
  endSourceDropPreview,
  endDropPreview: endSourceDropPreview,
  attachSources: groundSelection,
  setAttachmentURLs,
  setReferenceStatuses,
  setLinkTargets,
  insertAttachment,
  publicationHTML,
  runFormatCommand,
  activeFormats,
  openAIEdit,
  completeAIEdit,
  failAIEdit,
  setAIEditModel,
  refuseAIEditModel,
  openAIGenerate,
  completeImageGeneration,
  insertFileAttachment,
  setSlashFeatures,
  setJoinsPastedLines,
  completePastedLineJoining,
  forgetPastedLineJoining,
  runSlashRow,
  openInsertMenu,
  setFontSize(fontSize) {
    document.documentElement.style.setProperty('--artifact-font-size', `${fontSize}px`)
    scheduleMarginCardLayout()
  },
  setPageWidth,
  setMarginCardsShown,
  focus() {
    document.querySelector('.ProseMirror')?.focus()
  },
  // The notes graph (docs/notes-graph-design.md; the messages in PROTOCOL.md).
  setGraphContext,
  setBlocks,
  setReferences: setFootReferences,
  setDailyContext: setFootDaily,
  setBlockSearchResults,
  setBlockReferencesFor,
  revealBlock,
  /// What a save would write now, read from the document itself rather than
  /// from the last text the editor was handed: the round trip a harness
  /// checks (demo-notes.html).
  serializedMarkdown() {
    return editor ? markdownForStorage(editor.getMarkdown()) : ''
  },
}
