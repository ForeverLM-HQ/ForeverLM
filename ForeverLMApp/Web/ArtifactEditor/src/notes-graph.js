// What the notes graph draws around the writing rather than in it: the page
// foot (a day's activity, Linked References and, on a daily note, the days
// before it), the preview a block reference shows on
// hover, the list a referenced block's count opens, and the small menu a
// bullet's right-click opens (docs/notes-graph-design.md). Everything here is
// outside the contenteditable, so none of it can be typed into or saved; the
// host answers the questions it asks through the messages in PROTOCOL.md,
// posted with the editor's own `post`.

import { renderInline, renderMarkdown } from './notes-markdown.js'

let host = {
  post: () => {},
  snippetOptions: () => ({}),
}

/// The editor hands over how to post to the host and how a snippet resolves
/// references and titles.
export function connectNotesGraph(connection) {
  host = { ...host, ...connection }
}

function snippetOptions(extra = {}) {
  return { ...host.snippetOptions(), ...extra }
}

function element(tag, className, text) {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text != null) node.textContent = text
  return node
}

const chevronSVG = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="m3.75 4.75 2.25 2.5 2.25-2.5"/></svg>'

// ─── Following a link drawn in a snippet ────────────────────────────────────
// Snippets draw links as anchors with the address in a data attribute; one
// handler follows them all, wherever the snippet stands.

/// Follow the snippet link under an event, if any: true when it was one.
export function followSnippetLink(event) {
  const anchor = event.target instanceof Element ? event.target.closest('a') : null
  if (!anchor) return false
  if (anchor.dataset.title) {
    event.preventDefault()
    host.post('openTitleRequested', { title: anchor.dataset.title })
    return true
  }
  if (anchor.dataset.sourceId) {
    event.preventDefault()
    host.post('openSourceRequested', { href: `foreverlm://source/${encodeURIComponent(anchor.dataset.sourceId)}`, sourceID: anchor.dataset.sourceId })
    return true
  }
  if (anchor.dataset.href) {
    event.preventDefault()
    host.post('openLinkRequested', { href: anchor.dataset.href })
    return true
  }
  // A web address is followed by the page itself: the host opens it in the
  // browser (`decidePolicyFor`), as it does a link in the prose.
  return anchor.dataset.web === 'true'
}

/// An activity's address: a library source opens in Reader through the
/// message the host already answers for a source card; any other in-app
/// address is a link.
function openAddress(href) {
  const source = /^foreverlm:\/\/source\/([^/?#]+)/i.exec(String(href ?? ''))
  if (source) {
    let id = source[1]
    try { id = decodeURIComponent(id) } catch {}
    host.post('openSourceRequested', { href, sourceID: id })
    return
  }
  host.post('openLinkRequested', { href })
}

// ─── Floating panels ────────────────────────────────────────────────────────
// A preview, a reference list and a menu share one behaviour: placed under
// (or above) what opened them, never off the page, and put away by Escape, a
// press elsewhere, or the page scrolling under them.

const openPanels = new Set()

function placePanel(panel, rect, { gap = 6, preferAbove = false } = {}) {
  const margin = 8
  panel.style.left = '0px'
  panel.style.top = '0px'
  const width = panel.offsetWidth
  const height = panel.offsetHeight
  const left = Math.max(margin, Math.min(rect.left, window.innerWidth - width - margin))
  const below = rect.bottom + gap
  const above = rect.top - height - gap
  let top = preferAbove && above >= margin ? above : below
  if (top + height > window.innerHeight - margin && above >= margin) top = above
  panel.style.left = `${Math.round(left)}px`
  panel.style.top = `${Math.round(Math.max(margin, top))}px`
}

function closePanel(panel) {
  if (!panel || panel.hidden) return
  panel.hidden = true
  panel.replaceChildren()
  openPanels.delete(panel)
  panel.dispatchEvent(new CustomEvent('panelclosed'))
}

export function closeNotesPanels() {
  for (const panel of [...openPanels]) closePanel(panel)
}

function openPanel(panel) {
  panel.hidden = false
  openPanels.add(panel)
}

document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || openPanels.size === 0) return
  event.preventDefault()
  event.stopPropagation()
  closeNotesPanels()
}, true)

document.addEventListener('pointerdown', (event) => {
  if (openPanels.size === 0) return
  const inside = event.target instanceof Element && [...openPanels].some((panel) => panel.contains(event.target))
  if (inside) return
  // A press on what opened the panel toggles it in its own handler.
  if (event.target instanceof Element && event.target.closest('[data-notes-panel-anchor]')) return
  closeNotesPanels()
}, true)

document.addEventListener('scroll', (event) => {
  if (openPanels.size === 0) return
  if (event.target instanceof Element && [...openPanels].some((panel) => panel.contains(event.target))) return
  closeNotesPanels()
}, true)

window.addEventListener('resize', () => closeNotesPanels())

// ─── A block reference's preview ────────────────────────────────────────────

let previewPanel = null
let previewHideTimer = null
let previewShowTimer = null
let previewAnchor = null

/// The preview comes a beat after the pointer settles on a reference, so
/// moving across a line of text does not flash one up for every reference
/// it passes.
export function scheduleReferencePreview(anchor, blockID, block) {
  clearTimeout(previewShowTimer)
  clearTimeout(previewHideTimer)
  previewShowTimer = setTimeout(() => {
    if (anchor.isConnected) showReferencePreview(anchor, blockID, block)
  }, 250)
}

function ensurePreviewPanel() {
  if (previewPanel) return previewPanel
  previewPanel = element('div', 'artifact-graph-panel artifact-ref-preview')
  previewPanel.hidden = true
  previewPanel.setAttribute('role', 'dialog')
  previewPanel.addEventListener('mouseenter', () => clearTimeout(previewHideTimer))
  previewPanel.addEventListener('mouseleave', () => scheduleReferencePreviewHide())
  previewPanel.addEventListener('pointerdown', (event) => event.preventDefault())
  previewPanel.addEventListener('click', (event) => {
    if (followSnippetLink(event)) closePanel(previewPanel)
  })
  document.body.append(previewPanel)
  return previewPanel
}

/// Hovering a drawn reference shows the block it reads from: its page's
/// title, its words, and Open. `block` is the graph's answer, null when the
/// graph has no such block.
export function showReferencePreview(anchor, blockID, block) {
  clearTimeout(previewHideTimer)
  const panel = ensurePreviewPanel()
  if (previewAnchor === anchor && !panel.hidden) return
  previewAnchor = anchor
  const head = element('div', 'artifact-ref-preview-head')
  const title = element('span', 'artifact-ref-preview-title', block ? (block.docTitle || 'Untitled') : 'Block reference')
  head.append(title)
  if (block) {
    const open = element('button', 'artifact-graph-pill', 'Open')
    open.type = 'button'
    open.addEventListener('click', () => {
      closePanel(panel)
      host.post('openBlockRequested', { blockID })
    })
    head.append(open)
  }
  const body = element('div', 'artifact-ref-preview-body artifact-snippet')
  if (block) {
    const crumbs = Array.isArray(block.breadcrumbs) ? block.breadcrumbs.filter(Boolean) : []
    if (crumbs.length) body.append(breadcrumbsElement(crumbs))
    const words = element('div', 'artifact-ref-preview-words')
    words.innerHTML = renderInline(block.markdown ?? '', snippetOptions(), 1)
    body.append(words)
    if (block.childrenMarkdown) {
      const children = element('div', 'artifact-ref-preview-children')
      children.innerHTML = renderMarkdown(block.childrenMarkdown, snippetOptions({ foldListsDeeperThan: 1, depth: 1 }))
      body.append(children)
    }
  } else {
    body.append(element('div', 'artifact-graph-muted', 'No page in this library holds this block.'))
  }
  panel.replaceChildren(head, body)
  openPanel(panel)
  placePanel(panel, anchor.getBoundingClientRect())
}

export function scheduleReferencePreviewHide() {
  clearTimeout(previewShowTimer)
  clearTimeout(previewHideTimer)
  previewHideTimer = setTimeout(() => {
    previewAnchor = null
    closePanel(previewPanel)
  }, 180)
}

// ─── A referenced block's count, and where it is referenced ─────────────────

let referencesPanel = null
let referencesPanelBlockID = null

function ensureReferencesPanel() {
  if (referencesPanel) return referencesPanel
  referencesPanel = element('div', 'artifact-graph-panel artifact-block-references')
  referencesPanel.hidden = true
  referencesPanel.setAttribute('role', 'dialog')
  referencesPanel.setAttribute('aria-label', 'Linked References')
  referencesPanel.addEventListener('pointerdown', (event) => event.preventDefault())
  referencesPanel.addEventListener('click', (event) => {
    const row = event.target instanceof Element ? event.target.closest('[data-open-reference]') : null
    if (row && !(event.target instanceof Element && event.target.closest('a'))) {
      closePanel(referencesPanel)
      host.post('openReferenceRequested', JSON.parse(row.dataset.openReference))
      return
    }
    if (followSnippetLink(event)) closePanel(referencesPanel)
  })
  referencesPanel.addEventListener('panelclosed', () => { referencesPanelBlockID = null })
  document.body.append(referencesPanel)
  return referencesPanel
}

/// The count beside a referenced block was pressed: ask where it is
/// referenced and show the answer under it. A second press puts it away.
export function toggleBlockReferences(anchor, blockID) {
  const panel = ensureReferencesPanel()
  if (!panel.hidden && referencesPanelBlockID === blockID) {
    closePanel(panel)
    return
  }
  closeNotesPanels()
  referencesPanelBlockID = blockID
  panel.replaceChildren(element('div', 'artifact-graph-muted artifact-graph-loading', 'Finding references…'))
  panel.dataset.anchorRect = JSON.stringify(anchor.getBoundingClientRect())
  openPanel(panel)
  placePanel(panel, anchor.getBoundingClientRect())
  host.post('blockReferencesRequested', { blockID })
}

/// The host's answer to `blockReferencesRequested`. An answer for a block
/// whose list is no longer open is dropped.
export function fillBlockReferences(blockID, groups) {
  if (!referencesPanel || referencesPanel.hidden || referencesPanelBlockID !== blockID) return
  const list = Array.isArray(groups) ? groups : []
  const count = countReferences(list)
  const head = element('div', 'artifact-block-references-head', count === 1 ? '1 Linked Reference' : `${count} Linked References`)
  const body = element('div', 'artifact-block-references-body artifact-snippet')
  if (list.length === 0) body.append(element('div', 'artifact-graph-muted', 'Nothing references this block now.'))
  for (const group of list) body.append(referenceGroupElement(group, { compact: true }))
  referencesPanel.replaceChildren(head, body)
  let rect = null
  try { rect = JSON.parse(referencesPanel.dataset.anchorRect ?? 'null') } catch {}
  if (rect) placePanel(referencesPanel, rect)
}

// ─── The block menu ─────────────────────────────────────────────────────────

let menuPanel = null

function ensureMenuPanel() {
  if (menuPanel) return menuPanel
  menuPanel = element('div', 'artifact-graph-panel artifact-block-menu')
  menuPanel.hidden = true
  menuPanel.setAttribute('role', 'menu')
  menuPanel.addEventListener('pointerdown', (event) => event.preventDefault())
  menuPanel.addEventListener('contextmenu', (event) => event.preventDefault())
  document.body.append(menuPanel)
  return menuPanel
}

/// A small menu at a point: `items` is `[{ title, run, disabled }]`.
export function showBlockMenu(x, y, items) {
  closeNotesPanels()
  const panel = ensureMenuPanel()
  const buttons = items.map((item) => {
    const button = element('button', 'artifact-block-menu-item', item.title)
    button.type = 'button'
    button.setAttribute('role', 'menuitem')
    button.disabled = Boolean(item.disabled)
    button.addEventListener('click', () => {
      closePanel(panel)
      item.run()
    })
    return button
  })
  panel.replaceChildren(...buttons)
  openPanel(panel)
  placePanel(panel, { left: x, right: x, top: y, bottom: y }, { gap: 2 })
  buttons.find((button) => !button.disabled)?.focus({ preventScroll: true })
}

document.addEventListener('keydown', (event) => {
  if (!menuPanel || menuPanel.hidden) return
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
  const buttons = [...menuPanel.querySelectorAll('button:not(:disabled)')]
  if (buttons.length === 0) return
  event.preventDefault()
  event.stopPropagation()
  const index = buttons.indexOf(document.activeElement)
  const next = event.key === 'ArrowDown' ? (index + 1) % buttons.length : (index - 1 + buttons.length) % buttons.length
  buttons[next].focus({ preventScroll: true })
}, true)

// ─── Shared pieces of a reference list ──────────────────────────────────────

function breadcrumbsElement(crumbs) {
  const line = element('div', 'artifact-graph-crumbs')
  crumbs.forEach((crumb, index) => {
    if (index > 0) line.append(element('span', 'artifact-graph-crumb-separator', '›'))
    line.append(element('span', 'artifact-graph-crumb', crumb))
  })
  return line
}

export function countReferences(groups) {
  return (Array.isArray(groups) ? groups : []).reduce((sum, group) => {
    const blocks = Array.isArray(group?.blocks) ? group.blocks.length : 0
    return sum + (blocks || (group?.kind === 'idea' ? 1 : 0))
  }, 0)
}

/// One page's references: its title, a link, then each block with its
/// breadcrumbs above it and what is nested under it. A block opens that page
/// at that block; an Idea, which points as a whole, opens itself.
function referenceGroupElement(group, { compact = false } = {}) {
  const article = element('article', 'artifact-graph-group')
  article.dataset.kind = String(group?.kind ?? 'doc')
  const kind = ['doc', 'dailyNote', 'idea'].includes(group?.kind) ? group.kind : 'doc'
  const title = element('button', 'artifact-graph-group-title', group?.title || (kind === 'idea' ? 'Idea' : 'Untitled'))
  title.type = 'button'
  title.dataset.openReference = JSON.stringify({ kind, id: String(group?.id ?? '') })
  if (kind === 'idea') title.append(element('span', 'artifact-graph-kind', 'Idea'))
  article.append(title)
  for (const block of Array.isArray(group?.blocks) ? group.blocks : []) {
    const row = element('div', 'artifact-graph-block')
    row.dataset.openReference = JSON.stringify({
      kind,
      id: String(group?.id ?? ''),
      blockID: block?.blockID ?? undefined,
      plainText: String(block?.plainText ?? ''),
    })
    row.setAttribute('role', 'button')
    row.tabIndex = 0
    const crumbs = Array.isArray(block?.breadcrumbs) ? block.breadcrumbs.filter(Boolean) : []
    if (crumbs.length) row.append(breadcrumbsElement(crumbs))
    const words = element('div', 'artifact-graph-block-words')
    words.innerHTML = renderInline(block?.markdown ?? '', snippetOptions())
    row.append(words)
    if (block?.childrenMarkdown && !compact) {
      const children = element('div', 'artifact-graph-block-children')
      children.innerHTML = renderMarkdown(block.childrenMarkdown, snippetOptions({ foldListsDeeperThan: 2 }))
      row.append(children)
    }
    article.append(row)
  }
  return article
}

// ─── The page foot ──────────────────────────────────────────────────────────
// Below the writing, inside the page's scroll, in the order Roam keeps them:
// what the day held in the library (a daily note), Linked References, and a
// daily note's earlier days with More days. A section with nothing in it is
// not drawn; a host that sends nothing draws nothing. Roam's Unlinked
// References are not drawn (product owner, 2026-10-19: "no unlinked
// references should randomly show up"): a page titled with a common word
// filled its foot with other Pages' prose.

let footRoot = null
let footReferences = null
let footDaily = null
// Which sections stand open. A page opens with Linked References open,
// whatever the last page was left as: the editor's web view is pooled and
// outlives the page it showed.
const footOpenOnArrival = { linked: true }
let footOpen = { ...footOpenOnArrival }
let requestedMoreBefore = null
/// How long a press waits for the host before it can be pressed again.
const answerTimeout = 8000

function ensureFoot() {
  if (footRoot) return footRoot
  footRoot = element('section', 'artifact-page-foot')
  footRoot.setAttribute('aria-label', 'References')
  footRoot.hidden = true
  footRoot.addEventListener('click', onFootClick)
  footRoot.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter' && event.key !== ' ') return
    const row = event.target instanceof Element ? event.target.closest('[data-open-reference][role="button"]') : null
    if (!row || row !== event.target) return
    event.preventDefault()
    host.post('openReferenceRequested', JSON.parse(row.dataset.openReference))
  })
  const editorRoot = document.getElementById('editor')
  if (editorRoot) editorRoot.after(footRoot)
  else document.body.append(footRoot)
  return footRoot
}

function onFootClick(event) {
  const target = event.target instanceof Element ? event.target : null
  if (!target) return
  const toggle = target.closest('[data-foot-toggle]')
  if (toggle) {
    const name = toggle.dataset.footToggle
    footOpen[name] = !footOpen[name]
    renderFoot()
    return
  }
  const day = target.closest('[data-day-key]')
  if (day) {
    host.post('dailyNoteRequested', { dayKey: day.dataset.dayKey })
    return
  }
  const more = target.closest('[data-more-days]')
  if (more) {
    const before = more.dataset.moreDays
    requestedMoreBefore = before
    renderFoot()
    host.post('dailyNotesMoreRequested', { before })
    setTimeout(() => {
      if (requestedMoreBefore !== before) return
      requestedMoreBefore = null
      renderFoot()
    }, answerTimeout)
    return
  }
  const activity = target.closest('[data-activity-href]')
  if (activity) {
    openAddress(activity.dataset.activityHref)
    return
  }
  if (target.closest('a') && followSnippetLink(event)) return
  if (target.closest('summary, details')) return
  const reference = target.closest('[data-open-reference]')
  if (reference) {
    // Selecting words in a block is reading it, not following it.
    if (String(window.getSelection?.() ?? '').trim()) return
    host.post('openReferenceRequested', JSON.parse(reference.dataset.openReference))
  }
}

function sectionHeader(name, title, open) {
  const button = element('button', 'artifact-foot-heading')
  button.type = 'button'
  button.dataset.footToggle = name
  button.setAttribute('aria-expanded', String(open))
  const chevron = element('span', 'artifact-foot-chevron')
  chevron.innerHTML = chevronSVG
  button.append(chevron, element('span', '', title))
  return button
}

const activityWords = {
  read: 'Read',
  listened: 'Listened',
  watched: 'Watched',
  highlight: 'Highlighted',
  chat: 'Asked',
  doc: 'Wrote',
  card: 'Reviewed',
}

function dailySection(daily) {
  const activity = Array.isArray(daily?.activity) ? daily.activity : []
  if (activity.length === 0) return null
  const section = element('section', 'artifact-foot-section artifact-foot-daily')
  // "Today" or "That day", plainly: the list under it says it is the
  // library's (2026-10-06; it read "✦ Today in your library").
  section.append(element('h2', 'artifact-foot-title', daily.isToday ? 'Today' : 'That day'))
  const list = element('ul', 'artifact-foot-activity')
  for (const item of activity) {
    const row = element('li', 'artifact-foot-activity-row')
    row.dataset.kind = String(item?.kind ?? '')
    row.append(element('span', 'artifact-foot-activity-kind', activityWords[item?.kind] ?? 'Opened'))
    const title = element(item?.href ? 'button' : 'span', 'artifact-foot-activity-title', item?.title || 'Untitled')
    if (item?.href) {
      title.type = 'button'
      title.dataset.activityHref = String(item.href)
    }
    row.append(title)
    if (item?.detail) row.append(element('span', 'artifact-foot-activity-detail', item.detail))
    list.append(row)
  }
  section.append(list)
  return section
}

function linkedSection(linked) {
  const groups = Array.isArray(linked) ? linked : []
  const count = countReferences(groups)
  if (count === 0) return null
  const section = element('section', 'artifact-foot-section artifact-foot-linked')
  section.append(sectionHeader('linked', count === 1 ? '1 Linked Reference' : `${count} Linked References`, footOpen.linked))
  if (footOpen.linked) {
    const body = element('div', 'artifact-foot-body artifact-snippet')
    for (const group of groups) body.append(referenceGroupElement(group))
    section.append(body)
  }
  return section
}

/// The days before, each drawn whole under its date. A day with nothing
/// written is left out (2026-10-06): it drew its date over "Nothing
/// written.", a row of absence for every quiet day. More days still pages
/// from the last day the host sent, written in or not.
function daysSection(daily) {
  const days = Array.isArray(daily?.earlier) ? daily.earlier : []
  const written = days
    .map((day) => ({ day, markdown: String(day?.markdown ?? '').trim() }))
    .filter(({ markdown }) => markdown)
  if (written.length === 0 && !daily?.hasMore) return null
  const section = element('section', 'artifact-foot-section artifact-foot-days')
  for (const { day, markdown } of written) {
    const article = element('article', 'artifact-foot-day')
    const title = element('button', 'artifact-foot-day-title', day?.title || day?.dayKey || '')
    title.type = 'button'
    title.dataset.dayKey = String(day?.dayKey ?? '')
    const body = element('div', 'artifact-foot-day-body artifact-snippet')
    body.innerHTML = renderMarkdown(markdown, snippetOptions({ foldListsDeeperThan: 3 }))
    article.append(title, body)
    section.append(article)
  }
  if (daily?.hasMore) {
    const last = days.at(-1)?.dayKey ?? daily.dayKey
    const more = element('button', 'artifact-graph-pill artifact-foot-more', requestedMoreBefore === last ? 'Loading…' : 'More days')
    more.type = 'button'
    more.dataset.moreDays = String(last ?? '')
    more.disabled = requestedMoreBefore === last
    section.append(more)
  }
  return section
}

function renderFoot() {
  const sections = [
    footDaily ? dailySection(footDaily) : null,
    footReferences ? linkedSection(footReferences.linked) : null,
    footDaily ? daysSection(footDaily) : null,
  ].filter(Boolean)
  if (sections.length === 0) {
    if (footRoot) {
      footRoot.hidden = true
      footRoot.replaceChildren()
    }
    document.body.classList.remove('has-page-foot')
    return
  }
  const root = ensureFoot()
  // Drawn again whenever the graph changes (after every save): what the
  // reader unfolded stays unfolded.
  const opened = [...root.querySelectorAll('details')].map((details) => details.open)
  root.replaceChildren(...sections)
  const disclosures = [...root.querySelectorAll('details')]
  if (disclosures.length === opened.length) disclosures.forEach((details, index) => { details.open = opened[index] })
  root.hidden = false
  document.body.classList.add('has-page-foot')
}

/// `setReferences`: `{ linked: [Group] }`, or null.
export function setFootReferences(references) {
  footReferences = references && typeof references === 'object' ? references : null
  renderFoot()
}

/// `setDailyContext`: a daily note's day, or null for any other doc.
export function setFootDaily(daily) {
  const next = daily && typeof daily === 'object' ? daily : null
  if (next?.dayKey !== footDaily?.dayKey) requestedMoreBefore = null
  else if (next && requestedMoreBefore && (next.earlier ?? []).length !== (footDaily?.earlier ?? []).length) requestedMoreBefore = null
  footDaily = next
  renderFoot()
}

/// Draw the foot again: the block texts and titles it resolves have changed.
export function refreshFoot() {
  if (footReferences || footDaily) renderFoot()
}

/// Another page arrived in the editor: its foot opens as a fresh page's does.
export function foldFootForNewPage() {
  footOpen = { ...footOpenOnArrival }
}

export function clearFoot() {
  footReferences = null
  footDaily = null
  requestedMoreBefore = null
  renderFoot()
}

