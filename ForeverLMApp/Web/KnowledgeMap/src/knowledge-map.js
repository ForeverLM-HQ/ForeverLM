// The Map: a plane for what the learner thinks (docs/knowledge-map-design.md).
// Their Ideas, the regions they draw around them and the arrows between them
// are what sit on it; an Idea's sources hang under it as evidence, and a
// source is drawn only where the learner placed it, as an Idea's evidence, or
// in a lens a chat shows. Nothing waits on the plane unplaced: the pane's
// Library sidebar and its add box (Find or add) hold what is not on the map yet.
//
// A classic script with no dependencies, so the Mac loads it over file:// in a
// WKWebView, where module imports are blocked. It draws and takes
// pointer input only. What a card says, where the learner put it and what a
// lens shows all come from the host; every change the learner makes goes back
// to the host as a message, and the host writes it.
//
// Semantic zoom: each card has four faces (a dot, a title, a card, a card with
// detail) and the face is picked by how many screen pixels the card covers, so
// zooming out turns papers into regions and zooming in turns them back into
// text. The camera is a scale and an offset; nothing moves in world space when
// the learner zooms.
(function () {
  'use strict'

  const CARD_W = 240
  const CARD_H = 120
  // A clip (a box cut out of a PDF page in the Reader) is as wide as any card
  // and as tall as its picture: the host sends its height (`node.h`), which
  // ends in this foot for its name and the learner's note.
  const CLIP_FOOT = 46
  // What a figure clip's foot grows by to show the figure's printed caption
  // under its name (`KnowledgeMap.clipCaptionHeight` on the host).
  const CAPTION_ROOM = 32
  // A region the learner folded up draws this tall: its name above it, and
  // its cards not drawn at all (they stay placed where they are).
  const FOLDED_H = 64
  // A card folded to its title line is this tall (Heptabase's fold); the least
  // and the most a card can be sized to, and the least a region can be.
  const FOLD_H = 40
  const MIN_CARD_W = 160, MAX_CARD_W = 720, MIN_CARD_H = 56
  const MIN_REGION_W = 200, MIN_REGION_H = 120
  // An Idea's words at 1:1: its padding, and the lines an automatic height reads.
  const IDEA_PAD = 14
  const IDEA_TITLE_LINES = 8, IDEA_NOTE_LINES = 10
  // The room the disclosure triangle takes before a region's name.
  const CHEV = 16
  const GAP = 30
  // An Idea's evidence: small cards in rows of three under it.
  const EV_W = 150
  const EV_H = 64
  const EV_GAP = 10
  const EV_COLS = 3
  const MIN_SCALE = 0.02
  const MAX_SCALE = 4
  const VIEW_REPORT_MS = 250
  const LENS_MS = 520
  // How long a card takes to slide to where the layout puts it, and to fade
  // in when it comes onto the plane.
  const MOVE_MS = 260
  const APPEAR_MS = 200
  // Alignment guides while free cards are carried.
  const GUIDE = '#ff3b6b'
  // ForeverLM's proposals (Ask the Canvas) are drawn as ghosts this faint,
  // each in a free slot near the cards it answers, with room kept under it
  // for its ✦ line, and never closer than the margin to anything else.
  const GHOST_ALPHA = 0.78
  const WHY_ROOM = 56
  const GHOST_MARGIN = 12
  // The Memory layer: a card not reviewed for a long while is drawn this
  // faint, under a hatch.
  const DUSTY_ALPHA = 0.5
  // Review in place: the card reviewed is this wide on screen with its middle
  // this far across the view, leaving the right side to the question; the
  // flight there; how often its spot is told to the host while the camera
  // moves; how long its ring pulses.
  const REVIEW_W = 260
  const REVIEW_X = 0.35
  const REVIEW_MS = 560
  const REVIEW_ANCHOR_MS = 50
  const REVIEW_PULSE_MS = 3300

  const TYPE_TINTS = {
    paper: '#378ADD', article: '#1D9E75', podcast: '#7F77DD', video: '#D85A30',
    book: '#BA7517', meeting: '#888780', course: '#639922', xPost: '#5F5E5A',
    idea: '#EF9F27', other: '#888780', clip: '#D4537E', page: '#5B6B7F',
    doc: '#5F5E5A', site: '#0F6E56', animation: '#7F77DD', audio: '#993556', reading: '#BA7517',
    picture: '#8E6BBF', chat: '#5AC8FA', canvas: '#7F77DD',
  }
  const TYPE_NAMES = {
    paper: 'Paper', article: 'Article', podcast: 'Podcast', video: 'Video', book: 'Book',
    meeting: 'Meeting', course: 'Course', xPost: 'Post', other: 'Source',
    doc: 'Page', site: 'Site', animation: 'Animation', audio: 'Audio overview', reading: 'Reading', clip: 'Clip', page: 'Page',
    picture: 'Picture', chat: 'Chat', canvas: 'Canvas',
  }
  const TOOL_KEYS = { v: 'select', h: 'hand', c: 'circle', r: 'region', a: 'connect', n: 'note' }
  const REGION_TINTS = ['#7F77DD', '#1D9E75', '#D85A30', '#D4537E', '#BA7517', '#378ADD', '#639922', '#888780']

  // What Sapience showed (docs/knowledge-map-design.md, "What Sapience showed"):
  // a paper drawn as one page of its PDF, the learner's words about a card on
  // this canvas, an Idea as plain words, a question's badge, and a mind map's
  // small nodes. The four size formulas below are the Mac's as well
  // (`KnowledgeMap.pageFaceHeight`, `annotationHeight`, `treeNodeSize`,
  // `pageFaceFootHeight`): the Mac arranges cards with the same numbers, so a
  // card is as tall where it is drawn as where it was set down.
  const PAGE_FOOT = 70
  const LETTER_ASPECT = 0.7727
  const ANN_PAD = 10, ANN_LINE_H = 16, ANN_CHAR_W = 6.5, ANN_SIDE = 28, ANN_MAX_LINES = 12, ANN_MAX_CHARS = 600
  // The ✓ read mark, the open question's badge, and the junction of a bundle
  // (how far off the card's side the arrows meet).
  const QUESTION_TINT = '#D85A30'
  const BADGE_R = 8
  const JUNCTION = 28
  const STANCE_KEYS = ['supports', 'contradicts']

  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)) }
  // Characters as the Mac counts them (Swift's `count`: grapheme clusters).
  const graphemes = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter() : null
  function charCount(text) {
    const t = String(text || '')
    return graphemes ? [...graphemes.segment(t)].length : Array.from(t).length
  }
  function pageFaceFootHeight() { return PAGE_FOOT }
  // A page face's height: the page at the card's width (US Letter until the
  // PDF has been read), clamped to half to 2.7 times the width, and the foot.
  function pageFaceHeight(aspect, width) {
    const a = aspect > 0 ? aspect : LETTER_ASPECT
    return Math.round(clamp(width / a, 0.5 * width, 2.7 * width)) + pageFaceFootHeight()
  }
  // The lines an annotation takes: each paragraph its characters at 6.5 points
  // over the room beside the card's padding, at most 12 in all.
  function annotationLineCount(text, width) {
    if (!text) return 0
    const room = Math.max(1, width - ANN_SIDE)
    let lines = 0
    // Split as the Mac's `isNewline` does: CR LF is one break.
    for (const paragraph of String(text).split(/\r\n|[\n\r\u000B\u000C\u0085\u2028\u2029]/)) {
      lines += Math.max(1, Math.ceil(charCount(paragraph) * ANN_CHAR_W / room))
      if (lines >= ANN_MAX_LINES) return ANN_MAX_LINES
    }
    return lines
  }
  function annotationHeight(text, width) {
    const lines = annotationLineCount(text, width)
    return lines ? ANN_PAD + lines * ANN_LINE_H : 0
  }
  // A mind-map node's box from its words: the root is bigger than the rest.
  function treeNodeSize(title, role) {
    const root = role === 'root'
    const charW = root ? 8.6 : 7.0, padX = root ? 18 : 12, padY = root ? 12 : 7, lineH = root ? 21 : 17
    const minW = root ? 120 : 60, maxW = root ? 280 : 220
    const textW = charCount(title) * charW
    const w = clamp(textW + 2 * padX, minW, maxW)
    // Less a hair, as the Mac's: words that just fill a line are one line,
    // not two by rounding noise (a root of 14 characters, say).
    const lines = Math.min(4, Math.max(1, Math.ceil(textW / (w - 2 * padX) - 1e-9)))
    return { w: Math.round(w), h: Math.round(2 * padY + lines * lineH) }
  }
  // An Idea whose title ends with ? or ？ is a question.
  function isQuestionTitle(title) { return /[?？]$/.test(String(title || '').trim()) }

  function create(canvas, host) {
    // `let`: an export draws the plane once onto another canvas (`exportImage`).
    let ctx = canvas.getContext('2d')
    const state = {
      nodes: [], byRef: new Map(), links: [],
      // The learner's notebooks, by id: {id, title, summary, refs}, for the
      // regions that are a notebook's frame.
      notebooks: new Map(),
      placements: {}, regions: {}, edges: {},
      evidence: new Map(), fan: new Map(),
      scale: 0.2, ox: 0, oy: 0,
      tool: 'select', selection: new Set(), selectedRegion: null, selectedEdge: null,
      highlight: new Set(), lens: null, lensT: 1, lensFrom: null,
      drag: null, lasso: null, hover: null, dark: false,
      summaries: { clusters: {}, regions: {} },
      // Each source's picture (a cover, a PDF's first page, artwork), by ref, as the Mac sends them.
      thumbs: new Map(),
      // Series stacks: the ones the learner fanned out, the layout worked out
      // for the current placements, and the fold pills drawn this frame.
      openStacks: new Set(), stackCache: null, stackPills: [],
      // Where each region's name was drawn this frame, on screen, so the name
      // takes a click as the frame's own.
      labelHits: [],
      // Where each region's disclosure triangle was drawn this frame, on screen.
      chevronHits: [],
      // The cards and regions a folded region hides, worked out once per layout.
      hiddenCache: null,
      // Regions inside regions, read from their rects (`regionTree`), worked
      // out once per layout.
      regionTree: null,
      font: 'system-ui, -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif',
      dirty: true, viewTimer: 0, ready: false, firstContent: true,
      // While the Map is extended to another display: the edge facing the
      // other window and the gap to it, the camera last told to the host,
      // and the other window's drag in progress.
      link: null, follows: false, lastCam: null, preview: null, previewRegion: null, previewTimer: 0,
      // Motion: the slides in progress and where each card and frame was drawn
      // last frame, the cards fading in, and whether the plane has been drawn
      // with its cards once (the first ones do not fade in).
      moves: new Map(), last: new Map(), born: new Map(), regionMoves: new Map(), regionLast: new Map(), regionWMoves: new Map(), regionWLast: new Map(), settled: false,
      // Space held: the pointer pans. The camera a zoom is flying to.
      spaceHeld: false, voiceHeld: false, camTarget: null, nudge: null,
      // ForeverLM's proposals: the set showing ({id, tool, title, anchor,
      // proposals}); each ghost as laid out, by proposal id; the ghost (and
      // its button) under the pointer and the one picked; the ones kept or
      // dismissed here that the host has not taken back yet; where each was
      // drawn this frame, for hit tests; the positions last told to the host.
      proposals: null, ghosts: new Map(), ghostsDirty: false, ghostHover: null, ghostPart: null, ghostSelected: null,
      ghostGone: new Map(), ghostHits: [], ghostButtons: [], ghostPosted: null, ghostPressAt: 0, ghostGoneTimer: 0,
      // The Memory layer: whether it shows, each card's marks by ref, each
      // region's sums (worked out once per layout), the hatch of dust.
      memory: { enabled: false, marks: new Map() }, regionMemo: null, hatch: null,
      // Written faces of source cards, by ref: {far, mid, near}.
      faces: { enabled: false, map: new Map() },
      // Review in place: the card reviewed, the camera to go back to and the
      // spot last told to the host.
      review: null, reviewTimer: 0,
      // This Mac's display switches (the host's `setDisplay`), the Idea being
      // edited in place, the handles drawn this frame, the tree edges
      // (`treeIndex`), an edit asked for before its Idea arrived, and an
      // export in progress (`exportImage`: the plane drawn once, offscreen).
      display: { minimap: false, focus: false },
      lockHits: [], edgePills: [], connectHover: null, pendingIdeas: [], stickyPeek: null, spaceTap: null,
      editor: null, handles: [], badgeHits: [], treeCache: null, pendingEdit: null, exporting: false, view: null, textEpoch: 0,
      // Where the pointer last was over the plane ([x, y] in view points, null
      // once it leaves), for the key that adds where the learner is looking; and
      // which ring (`ringCards`) is the latest, so an earlier one's timer does
      // not put out a later one.
      pointer: null, ringToken: 0,
      // What Sapience showed: each Idea's place in a mind map (`mindInfo`) and the
      // arrows that converge into one card (`bundles`), both worked out once per
      // layout; where the page faces' stepper pills and the questions' badges
      // were drawn this frame, on screen; and what the ghost tree of the set
      // showing remembers (`layoutGhostTree`).
      mindCache: null, bundleCache: null, pageHits: [], questionHits: [], ghostTree: null,
    }

    // ---- Theme

    function readTheme() {
      const st = getComputedStyle(document.documentElement)
      const v = (name, fallback) => st.getPropertyValue(name).trim() || fallback
      state.colors = {
        bg: v('--map-bg', '#fbfbfa'), dot: v('--map-dot', '#c9c9c6'),
        card: v('--map-card', '#ffffff'), flat: v('--map-flat', '#f2f2f0'), hairline: v('--map-hairline', 'rgba(0,0,0,0.06)'),
        text: v('--map-text', '#1d1d1f'), sub: v('--map-sub', '#6e6e73'), faint: v('--map-faint', '#98989d'),
        select: v('--map-select', '#0a84ff'), edge: v('--map-edge', '#a1a1a6'), shadow: v('--map-shadow', 'rgba(0,0,0,0.10)'),
        sticky: v('--map-sticky', '#fff3b0'), stickyText: v('--map-sticky-text', '#3d3200'), ai: v('--map-ai', '#7a6cc4'),
        // A proposed arrow that contradicts; how a card's kept cards stand.
        contra: v('--map-contra', '#cf4a3f'),
        memSolid: v('--map-mem-solid', '#2f9e5b'), memDue: v('--map-mem-due', '#d99211'), memFading: v('--map-mem-fading', '#c25b52'),
      }
      state.dark = matchMedia('(prefers-color-scheme: dark)').matches
      state.hatch = null
      state.textEpoch++
      if (typeof wrapCache !== 'undefined') wrapCache.clear()
      invalidate()
    }

    // ---- Geometry helpers

    function viewW() { return state.view ? state.view.w : canvas.clientWidth }
    function viewH() { return state.view ? state.view.h : canvas.clientHeight }
    function toWorld(px, py) { return [(px - state.ox) / state.scale, (py - state.oy) / state.scale] }
    function toScreen(x, y) { return [x * state.scale + state.ox, y * state.scale + state.oy] }
    function level() {
      const w = CARD_W * state.scale
      return w < 44 ? 0 : w < 120 ? 1 : w < 240 ? 2 : 3
    }

    function resize() {
      const d = window.devicePixelRatio || 1
      canvas.width = Math.max(1, Math.round(viewW() * d))
      canvas.height = Math.max(1, Math.round(viewH() * d))
      invalidate()
    }

    // Where a node is drawn right now, or null when it is not on the plane:
    // where the learner placed it (or the other display's drag has it), else
    // under its Idea as evidence. A lens moves it to the lens's spot, eased
    // between the two while the lens comes or goes.
    function basePos(node) {
      const v = state.preview && state.preview.get(node.ref)
      if (v) return [v.x, v.y]
      const carried = state.drag && state.drag.carrying
      const sp = !(carried && carried.has(node.ref)) && stackLayout().pos.get(node.ref)
      if (sp) return sp
      const p = state.placements[node.ref]
      if (p) return [p.x, p.y]
      const f = state.fan.get(node.ref)
      return f ? [f.x, f.y] : null
    }
    // Where a node is drawn this frame: where the layout puts it, or on its
    // way there (see Motion).
    function pos(node) {
      const m = !state.exporting && state.moves.get(node.ref)
      return m ? m.cur : targetPos(node)
    }
    // ---- Folded regions
    //
    // A region the learner folded up (`collapsed`) draws as its name and
    // count: the cards whose middle it holds, and the regions inside it, are
    // not drawn and take no press, though they stay placed where they are, in
    // the layout the host keeps. Worked out once per layout.
    function hidden() {
      if (state.hiddenCache) return state.hiddenCache
      const refs = new Set(), regions = new Set()
      const folded = Object.values(state.regions).filter(r => r.collapsed)
      if (folded.length) {
        const holds = (r, cx, cy) => cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h
        for (const [ref, p] of Object.entries(state.placements)) {
          const [cx, cy] = midOf(ref, p)
          if (folded.some(r => holds(r, cx, cy))) refs.add(ref)
        }
        for (const r of Object.values(state.regions)) {
          if (folded.some(f => f.id !== r.id && f.w * f.h > r.w * r.h && holds(f, r.x + r.w / 2, r.y + r.h / 2))) regions.add(r.id)
        }
      }
      // A card folded in a mind map hides everything that hangs from it.
      for (const [ref, p] of Object.entries(state.placements)) {
        if (p.folded) for (const d of treeDescendants(ref)) refs.add(d)
      }
      state.hiddenCache = { refs, regions }
      return state.hiddenCache
    }
    function hiddenByFold(ref) { return hidden().refs.has(ref) }
    function countWord(refs) {
      const pages = refs.length > 0 && refs.every(ref => { const n = state.byRef.get(ref); return n && n.kind === 'page' })
      return refs.length + (pages ? (refs.length === 1 ? ' page' : ' pages') : (refs.length === 1 ? ' card' : ' cards'))
    }

    function targetPos(node) {
      const base = hiddenByFold(node.ref) ? null : basePos(node)
      const lens = state.lens
      if (!lens) {
        if (state.lensFrom && state.lensT < 1) {
          const from = state.lensFrom.positions[node.ref]
          if (from) return base ? mix([from.x, from.y], base, ease(state.lensT)) : [from.x, from.y]
        }
        return base
      }
      const target = lens.positions[node.ref]
      if (!target) return base
      return state.lensT < 1 && base ? mix(base, [target.x, target.y], ease(state.lensT)) : [target.x, target.y]
    }
    // How present a node is: a card a lens brings in from off the plane fades
    // in with it, and out again when the lens goes.
    function presence(node) {
      if (basePos(node)) return 1
      if (state.lens && state.lens.positions[node.ref]) return ease(state.lensT)
      if (!state.lens && state.lensFrom && state.lensFrom.positions[node.ref] && state.lensT < 1) return 1 - ease(state.lensT)
      return 0
    }
    function shown(node) { return presence(node) > 0 }
    function mix(a, b, k) { return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k] }
    function ease(k) { return 1 - Math.pow(1 - k, 3) }
    function isPlaced(node) { return !!state.placements[node.ref] || !!(state.preview && state.preview.has(node.ref)) }
    function inLens(node) { return !state.lens || !!state.lens.positions[node.ref] }
    // A card drawn under its Idea is small; every other card is full size.
    function isFanned(node) {
      return !isPlaced(node) && state.fan.has(node.ref) && !stackLayout().pos.has(node.ref) && !(state.lens && state.lens.positions[node.ref])
    }
    // ---- Per-card geometry
    //
    // A card is CARD_W wide and its kind's height (CARD_H; a clip, page or
    // picture as tall as its picture) unless the learner sized it: a
    // placement may carry `w`, `h`, `folded` (drawn as its title line) and a
    // `color`. Everything that measures a card goes through these, never the
    // constants. While a lens shows, every card is its usual size: the lens's
    // layout was worked out for that.
    function placementOf(node) { return node ? state.placements[node.ref] : null }
    function cardW(node) {
      const p = !state.lens && placementOf(node)
      if (p && p.w > 0) return clamp(p.w, MIN_CARD_W, MAX_CARD_W)
      const mind = mindInfo(node)
      return mind ? treeNodeSize(node.title, mind.role).w : CARD_W
    }
    function isFoldedCard(node) { const p = !state.lens && placementOf(node); return !!(p && p.folded) }
    function cardColor(node) { const p = !state.lens && placementOf(node); return p && p.color ? p.color : null }
    // A card's height: its title line when folded, else what the learner sized
    // it to (which holds the annotation too), else its kind's own and, but for
    // an Idea, the room for the words about it. The Mac reads the same sizes.
    function cardH(node) {
      if (!node) return CARD_H
      const p = !state.lens && placementOf(node)
      if (p && p.folded) return FOLD_H
      if (p && p.h > 0) return Math.max(MIN_CARD_H, p.h)
      return ownH(node) + annotationH(node)
    }
    // A card's own height, without the room for an annotation.
    function ownH(node) {
      const mind = mindInfo(node)
      if (mind) return treeNodeSize(node.title, mind.role).h
      if (isPageFace(node)) return pageFaceHeight(node.aspect, cardW(node))
      if (node.h) return node.h
      return node.kind === 'idea' ? ideaAutoH(node) : CARD_H
    }
    // A source whose paper the card shows as a page: its placement says which
    // page, and this Mac has read the PDF (`pages`). A lens shows usual cards.
    function isPageFace(node) {
      if (!node || node.kind !== 'source' || state.lens || !(node.pages > 0)) return false
      const p = placementOf(node)
      return !!(p && p.page > 0)
    }
    // The page a page face shows, kept within the PDF.
    function pageOf(node) { return Math.min(placementOf(node).page, node.pages) }
    function isPlain(node) { const p = !state.lens && placementOf(node); return !!(p && p.plain && node.kind === 'idea') }
    // The learner's words about a card on this canvas: the editor's, as typed,
    // while it is open on this card (so the card grows with them).
    function annotationOf(node) {
      if (!node || node.kind === 'idea') return ''
      const ed = state.editor
      if (ed && ed.kind === 'annotation' && ed.ref === node.ref) return ed.text
      const p = !state.lens && placementOf(node)
      return p && p.annotation ? p.annotation : ''
    }
    function annotationH(node) {
      if (isFoldedCard(node)) return 0
      return annotationHeight(annotationOf(node), cardW(node))
    }
    // Where an Idea sits in a mind map: {regionID, role} for an Idea placed in a
    // region laid out as a tree with no size or fold of its own, else null. The
    // region is read from the stored spot at the usual card's middle (as the Mac
    // reads it), never from where the tree draws it, so a node's size does not
    // depend on the layout that is made of the sizes. Its role: a root when no
    // branch leads to it, a branch when one leads from it, else a leaf.
    function mindInfo(node) {
      if (!node || node.kind !== 'idea' || state.lens) return null
      const cache = state.mindCache || (state.mindCache = new Map())
      if (cache.has(node.ref)) return cache.get(node.ref)
      let info = null
      const p = state.placements[node.ref]
      if (p && !(p.w > 0) && !(p.h > 0) && !p.folded) {
        const mx = p.x + CARD_W / 2, my = p.y + CARD_H / 2
        let home = null
        for (const r of Object.values(state.regions)) {
          if (mx >= r.x && mx <= r.x + r.w && my >= r.y && my <= r.y + r.h && (!home || r.w * r.h < home.w * home.h)) home = r
        }
        if (home && home.layout === 'tree' && !notebookOf(home)) {
          const { kids, parent } = treeIndex()
          info = { regionID: home.id, role: !parent.has(node.ref) ? 'root' : (kids.get(node.ref) || []).length ? 'branch' : 'leaf' }
        }
      }
      cache.set(node.ref, info)
      return info
    }
    // A mind map's colour for a node: the root the region's tint, a branch's
    // own colour (each child of a root takes the next tint after the region's)
    // for the cards under it.
    function nodeTint(node, mind) {
      const r = state.regions[mind.regionID]
      const own = r && r.color ? r.color : REGION_TINTS[0]
      return mind.role === 'root' ? own : stackLayout().branchTint.get(node.ref) || own
    }
    // An Idea's note: its sub line, unless that is just the word Idea.
    function ideaNote(node) { return node && node.kind === 'idea' && node.sub && node.sub !== 'Idea' ? node.sub : '' }
    // An Idea with no height of its own is as tall as its words at 1:1 (the
    // title and note wrapped to its width, and the evidence line under them),
    // never less than the usual card: it grows to hold what it says.
    function ideaAutoH(node) {
      if (String(node.ref).startsWith('proposal:')) return CARD_H
      const w = cardW(node)
      const key = w + '|' + state.textEpoch
      if (node._auto && node._auto.key === key) return node._auto.h
      const keep = ctx.font
      const tw = w - IDEA_PAD * 2
      // A question's badge takes the room before its title.
      const tl = wrapLines(node.title, '500 14px ' + state.font, tw - (isQuestionTitle(node.title) ? BADGE_R * 2 + 6 : 0), IDEA_TITLE_LINES).length
      const note = ideaNote(node)
      const nl = note ? wrapLines(note, '12.5px ' + state.font, tw, IDEA_NOTE_LINES).length : 0
      ctx.font = keep
      const evidence = (state.evidence.get(node.ref) || []).length
      const h = Math.ceil(IDEA_PAD * 0.85 + tl * 18 + 3 + (nl ? 4 + nl * 16 : 0) + (evidence ? 26 : 12))
      node._auto = { key, h: Math.max(CARD_H, h) }
      return node._auto.h
    }
    // A card in a region laid out in rows is drawn in a CARD_W column.
    function flowed(node) { return stackLayout().fixedW.has(node.ref) }
    function sizeOf(node) { return isFanned(node) ? [EV_W, EV_H] : [flowed(node) ? CARD_W : cardW(node), cardH(node)] }
    // A placed card as a box, for what hangs off it (an Idea's evidence).
    function placedBox(ref) {
      const p = state.placements[ref]
      if (!p) return null
      const n = state.byRef.get(ref)
      return { x: p.x, y: p.y, w: n ? cardW(n) : CARD_W, h: n ? cardH(n) : CARD_H }
    }
    // The middle of a card placed at `p`, the point that decides which region
    // holds it: its true middle once the learner sized it, else the usual
    // card's (a tall clip is held by its top, as the host reads it).
    function midOf(ref, p) {
      const node = state.byRef.get(ref)
      const q = state.placements[ref]
      const sized = !!(node && q && (q.h > 0 || q.folded))
      // A mind map's node is held at the usual card's middle, as the Mac reads it.
      const wide = !!(node && q && q.w > 0 && !state.lens)
      return [p.x + (wide ? cardW(node) : CARD_W) / 2, p.y + (sized ? cardH(node) : CARD_H) / 2]
    }
    // Moves a placed card, keeping what the learner sized.
    function spotAt(ref, x, y) { return Object.assign({}, state.placements[ref], { x, y }) }
    // The mind map's edges (`tree: true`, parent to child): each card's
    // children in the order the edges are keyed, and its parent.
    function treeIndex() {
      if (state.treeCache) return state.treeCache
      const kids = new Map(), parent = new Map()
      for (const e of Object.values(state.edges)) {
        if (!e.tree || String(e.from).startsWith('region:') || String(e.to).startsWith('region:')) continue
        if (!kids.has(e.from)) kids.set(e.from, [])
        kids.get(e.from).push(e.to)
        if (!parent.has(e.to)) parent.set(e.to, e.from)
      }
      return (state.treeCache = { kids, parent })
    }
    function treeDescendants(ref) {
      const { kids } = treeIndex()
      const out = [], seen = new Set([ref])
      const walk = (r) => { for (const k of kids.get(r) || []) if (!seen.has(k)) { seen.add(k); out.push(k); walk(k) } }
      walk(ref)
      return out
    }

    // ---- Evidence: the sources and Docs an Idea is linked to. They hang
    // under a placed Idea in rows of three while it is selected or the zoom
    // is close enough for detail; one the learner placed elsewhere is joined
    // to its Idea by a thread instead.

    function layoutFan(L) {
      state.fan = new Map()
      if (state.lens) return
      for (const [ideaRef, refs] of state.evidence) {
        const idea = placedBox(ideaRef)
        if (!idea) continue
        if (!(L === 3 || state.selection.has(ideaRef) || refs.some(ref => state.selection.has(ref)))) continue
        const framed = stackLayout().pos
        const loose = refs.filter(ref => !state.placements[ref] && !framed.has(ref) && !(state.preview && state.preview.has(ref)))
        if (!loose.length) continue
        const cols = Math.min(EV_COLS, loose.length)
        const rowW = cols * (EV_W + EV_GAP) - EV_GAP
        const x0 = idea.x + idea.w / 2 - rowW / 2
        const y0 = idea.y + idea.h + 26
        loose.forEach((ref, i) => {
          if (state.fan.has(ref)) return
          state.fan.set(ref, { x: x0 + (i % cols) * (EV_W + EV_GAP), y: y0 + Math.floor(i / cols) * (EV_H + EV_GAP), idea: ideaRef })
        })
      }
    }

    // The regions as drawn: a region the other window is moving or resizing
    // shows where it is now, and a frame laid out in rows is as tall as its
    // rows (growing or shrinking to them, see Motion).
    // Every region as drawn, the larger first, so a region inside another is
    // drawn over it.
    function shownRegions() {
      const list = Object.values(state.regions).filter(r => !hidden().regions.has(r.id)).sort((a, b) => b.w * b.h - a.w * a.h)
      const pr = state.previewRegion
      if (pr) return list.map(r => r.id === pr.id ? Object.assign({}, r, pr) : r)
      return list.map(r => { const h = shownH(r), w = shownW(r); return h === r.h && w === r.w ? r : Object.assign({}, r, { h, w }) })
    }
    function targetH(r) {
      if (r.collapsed) return Math.min(r.h, FOLDED_H)
      const h = stackLayout().regionH.get(r.id)
      return h == null ? r.h : h
    }
    // A mind map's region is never narrower than its tree.
    function targetW(r) {
      if (r.collapsed) return r.w
      const w = stackLayout().regionW.get(r.id)
      return w == null ? r.w : Math.max(r.w, w)
    }
    function shownW(r) { const m = !state.exporting && state.regionWMoves.get(r.id); return m ? m.cur : targetW(r) }
    function shownH(r) { const m = !state.exporting && state.regionMoves.get(r.id); return m ? m.cur : targetH(r) }

    function worldBounds(refs) {
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
      for (const ref of refs) {
        const node = state.byRef.get(ref)
        if (!node) continue
        const p = pos(node)
        if (!p) continue
        const [w, h] = sizeOf(node)
        minX = Math.min(minX, p[0]); minY = Math.min(minY, p[1])
        maxX = Math.max(maxX, p[0] + w); maxY = Math.max(maxY, p[1] + h)
      }
      return minX === Infinity ? null : { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
    }

    // What is on the plane: the placed cards and regions, or the lens's.
    function allBounds() {
      const refs = state.lens ? Object.keys(state.lens.positions) : Object.keys(state.placements)
      let b = worldBounds(refs)
      if (!state.lens) for (const r of Object.values(state.regions)) b = union(b, r)
      return b || { x: -700, y: -450, w: 1400, h: 900 }
    }
    function union(a, b) {
      if (!a) return { x: b.x, y: b.y, w: b.w, h: b.h }
      const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y)
      return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y }
    }

    // ---- Camera

    let camAnim = 0
    let pendingFit = null
    function fitTo(b, instant, padding, onDone) {
      if (!b) return
      if (viewW() < 2 || viewH() < 2) { pendingFit = b; return }
      const pad = padding == null ? 60 : padding
      const s = clamp(Math.min((viewW() - pad * 2) / Math.max(b.w, 1), (viewH() - pad * 2) / Math.max(b.h, 1)), MIN_SCALE, MAX_SCALE)
      const ox = viewW() / 2 - (b.x + b.w / 2) * s
      const oy = viewH() / 2 - (b.y + b.h / 2) * s
      if (instant) { stopCamera(); state.scale = s; state.ox = ox; state.oy = oy; redraw(); reportView(); if (onDone) onDone(); return }
      flyCamera(s, ox, oy, 460, onDone)
    }
    // The camera eases to a scale and offset; a flight asked for while one is
    // under way starts from where the camera is and aims for the new target.
    // `onDone` runs when it lands (not when it is cut short).
    function flyCamera(s, ox, oy, ms, onDone) {
      cancelAnimationFrame(camAnim)
      const s0 = state.scale, x0 = state.ox, y0 = state.oy, t0 = performance.now()
      state.camTarget = { scale: s, ox, oy }
      const step = (t) => {
        const k = ease(Math.min(1, (t - t0) / ms))
        // The scale eases in log space, so a zoom in and a zoom out feel alike.
        const sk = Math.exp(Math.log(s0) + (Math.log(s) - Math.log(s0)) * k)
        const f = s === s0 ? k : (sk - s0) / (s - s0)
        state.scale = sk; state.ox = x0 + (ox - x0) * f; state.oy = y0 + (oy - y0) * f
        // It lands exactly where it was aimed (a camera flown back to is the
        // camera that was left).
        if (k >= 1) { state.scale = s; state.ox = ox; state.oy = oy }
        redraw()
        if (k < 1) camAnim = requestAnimationFrame(step)
        else { camAnim = 0; state.camTarget = null; reportView(); if (onDone) onDone() }
      }
      camAnim = requestAnimationFrame(step)
    }
    function stopCamera() { cancelAnimationFrame(camAnim); camAnim = 0; state.camTarget = null }
    // A zoom about a point that follows the hand: a pinch, ⌘-scroll.
    function zoomAt(factor, px, py) {
      stopCamera()
      const s = clamp(state.scale * factor, MIN_SCALE, MAX_SCALE)
      state.ox = px - (px - state.ox) * (s / state.scale)
      state.oy = py - (py - state.oy) * (s / state.scale)
      state.scale = s
      redraw(); scheduleViewReport()
    }
    // A zoom step (the + and − keys, the zoom buttons): eased, and a second
    // step while the first is under way goes on from the first one's target.
    function zoomBy(factor, px, py) {
      const from = state.camTarget || { scale: state.scale, ox: state.ox, oy: state.oy }
      const s = clamp(from.scale * factor, MIN_SCALE, MAX_SCALE)
      flyCamera(s, px - (px - from.ox) * (s / from.scale), py - (py - from.oy) * (s / from.scale), 220)
    }

    // ---- Text

    const wrapCache = new Map()
    function wrapLines(text, font, maxW, maxLines) {
      const key = font + '|' + maxW + '|' + maxLines + '|' + text
      const hit = wrapCache.get(key)
      if (hit) return hit
      ctx.font = font
      const fits = (t) => ctx.measureText(t).width <= maxW
      const ellipsize = (t) => {
        if (fits(t)) return t
        while (t.length > 1 && !fits(t + '…')) t = t.slice(0, -1)
        return t + '…'
      }
      const words = String(text || '').split(/\s+/).filter(Boolean)
      const lines = []
      let line = ''
      let i = 0
      for (; i < words.length && lines.length < Math.max(1, maxLines); i++) {
        const test = line ? line + ' ' + words[i] : words[i]
        if (!fits(test) && line) {
          if (lines.length === Math.max(1, maxLines) - 1) break
          lines.push(line)
          line = words[i]
        } else line = test
      }
      if (line) {
        const rest = i < words.length ? line + ' ' + words.slice(i).join(' ') : line
        lines.push(i < words.length ? ellipsize(rest) : ellipsize(line))
      }
      if (wrapCache.size > 6000) wrapCache.clear()
      wrapCache.set(key, lines)
      return lines
    }
    function drawLines(lines, x, y, lh) { lines.forEach((l, i) => ctx.fillText(l, x, y + i * lh)) }

    // ---- Drawing
    //
    // The look follows Freeform: a quiet dotted plane, white cards that lift
    // off it with a soft shadow, an Idea's evidence as small flat cards
    // under it, Ideas as sticky notes, curved arrows
    // with their label on a pill, and regions as faint tinted fields with
    // their name in the corner. Colour is kept for meaning: a small dot for a
    // card's kind, a region's own tint, blue for selection.

    let frame = 0
    // A change to what is drawn where (a placement, a region, the cards): the
    // layout is worked out again on the next frame, and with it where the
    // ghosts go and what each region's kept cards add up to.
    function invalidate() {
      state.stackCache = null
      state.ghostsDirty = true
      state.regionMemo = null
      state.regionTree = null
      state.hiddenCache = null
      state.treeCache = null
      state.focusCache = null
      state.mindCache = null
      state.bundleCache = null
      mm.dirty = true
      redraw()
    }
    // A change to how it is seen only (the camera, a hover, a frame of an
    // animation): drawn again from the layout as it is.
    function redraw() {
      if (frame) return
      frame = requestAnimationFrame(() => { frame = 0; draw() })
    }

    function roundRect(x, y, w, h, r) {
      ctx.beginPath()
      if (ctx.roundRect) ctx.roundRect(x, y, w, h, r); else ctx.rect(x, y, w, h)
    }

    function withAlpha(hex, a) {
      const v = parseInt(String(hex).replace('#', ''), 16)
      if (Number.isNaN(v)) return hex
      return 'rgba(' + ((v >> 16) & 255) + ',' + ((v >> 8) & 255) + ',' + (v & 255) + ',' + a + ')'
    }

    // ---- Colour and glyphs for the learner's own tints
    function hexRGB(hex) {
      const v = parseInt(String(hex).replace('#', ''), 16)
      return Number.isNaN(v) ? null : [(v >> 16) & 255, (v >> 8) & 255, v & 255]
    }
    // An Idea tinted in place of the sticky yellow: the tint washed toward the
    // plane's own light (or dark), and whichever ink reads on that.
    const paletteCache = new Map()
    function ideaPalette(tc) {
      const key = tc + '|' + state.dark
      let p = paletteCache.get(key)
      if (!p) {
        const rgb = hexRGB(tc) || [250, 230, 140]
        const base = state.dark ? [44, 44, 46] : [255, 255, 255]
        const k = state.dark ? 0.6 : 0.32
        const f = rgb.map((v, i) => Math.round(base[i] + (v - base[i]) * k))
        const lum = (0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]) / 255
        p = { fill: 'rgb(' + f.join(',') + ')', ink: lum > 0.55 ? '#2b2b2e' : '#f5f5f7' }
        paletteCache.set(key, p)
      }
      return p
    }
    // A chat's speech bubble and a canvas's frame, `size` points square at (x, y).
    function drawKindGlyph(kind, x, y, size, tint) {
      const c = state.colors
      ctx.save()
      ctx.strokeStyle = tint; ctx.fillStyle = tint; ctx.lineWidth = 1.4; ctx.lineJoin = 'round'
      if (kind === 'chat') {
        const bh = size * 0.74
        roundRect(x, y + 1, size, bh, 3.5); ctx.fill()
        ctx.beginPath(); ctx.moveTo(x + 3, y + bh); ctx.lineTo(x + 2.5, y + bh + 4.5); ctx.lineTo(x + 7.5, y + bh); ctx.closePath(); ctx.fill()
        ctx.fillStyle = c.card
        for (let i = 0; i < 3; i++) { ctx.beginPath(); ctx.arc(x + size * 0.25 + i * size * 0.25, y + 1 + bh / 2, 1.1, 0, Math.PI * 2); ctx.fill() }
      } else {
        roundRect(x, y + 1, size, size * 0.82, 3); ctx.stroke()
        ctx.fillRect(x + 2.6, y + 3.6, size * 0.34, size * 0.26)
        ctx.fillRect(x + size * 0.55, y + 3.6 + size * 0.3, size * 0.34, size * 0.26)
      }
      ctx.restore()
    }
    // A small padlock whose body starts at x, middle at cy: a locked region's mark.
    function drawLock(x, cy, color) {
      ctx.save()
      ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = 1.4
      ctx.beginPath(); ctx.arc(x + 4.5, cy - 1.2, 2.8, Math.PI, 0); ctx.stroke()
      roundRect(x, cy - 1, 9, 7, 1.5); ctx.fill()
      ctx.restore()
    }
    // A card folded to its title: a triangle, the title on one line, and for a
    // card with a mind map under it the pill that says how many are hidden.
    function drawFoldedLine(node, x, y, w, h, radius, tint, textColor) {
      const pad = Math.max(8, 12 * state.scale)
      const kids = treeDescendants(node.ref).length
      const my = y + h / 2
      ctx.save(); roundRect(x, y, w, h, radius); ctx.clip()
      ctx.fillStyle = tint
      ctx.beginPath(); ctx.moveTo(x + pad, my - 4.5); ctx.lineTo(x + pad + 6, my); ctx.lineTo(x + pad, my + 4.5); ctx.closePath(); ctx.fill()
      const idea = node.kind === 'idea'
      ctx.font = (idea ? '500 ' : '600 ') + (idea ? 14 : 13) + 'px ' + state.font
      ctx.fillStyle = textColor
      ctx.textBaseline = 'middle'
      ctx.fillText(wrapLines(node.title, ctx.font, w - pad * 2 - 14 - (kids ? 22 : 0), 1)[0] || '', x + pad + 14, my + 0.5)
      ctx.textBaseline = 'top'
      ctx.restore()
      if (kids) drawTreeBadge(node, x + w, my, kids, tint)
    }
    function drawTreeBadge(node, rx, my, n, tint) {
      const c = state.colors
      ctx.font = '600 11px ' + state.font
      const text = '▸ ' + n
      const bw = ctx.measureText(text).width + 12, bh = 18
      const bx = rx - bw / 2, by = my - bh / 2
      ctx.save()
      ctx.shadowColor = c.shadow; ctx.shadowBlur = 5; ctx.shadowOffsetY = 1
      ctx.fillStyle = c.card
      roundRect(bx, by, bw, bh, 9); ctx.fill()
      ctx.restore()
      ctx.strokeStyle = withAlpha(tint, 0.6); ctx.lineWidth = 1
      roundRect(bx, by, bw, bh, 9); ctx.stroke()
      ctx.fillStyle = c.sub
      ctx.fillText(text, bx + 6, by + 3.5)
      state.badgeHits.push({ ref: node.ref, x: bx, y: by, w: bw, h: bh })
    }

    function drawGrid(W, H) {
      const c = state.colors
      let step = 32 * state.scale
      while (step < 14) step *= 4
      if (step > 400) return
      const alpha = Math.min(1, (step - 14) / 20)
      const ox = ((state.ox % step) + step) % step, oy = ((state.oy % step) + step) % step
      ctx.fillStyle = c.dot
      ctx.globalAlpha = 0.35 + 0.65 * alpha
      const r = 1
      for (let x = ox; x < W; x += step) {
        for (let y = oy; y < H; y += step) ctx.fillRect(x - r / 2, y - r / 2, r, r)
      }
      ctx.globalAlpha = 1
    }

    // ---- Motion
    //
    // Nothing on the plane jumps. When the layout puts a card somewhere new (a
    // drop settling into its slot, a series folding or fanning out, a region
    // reflowing to a new width, the other Mac's move arriving), the card
    // slides there from where it was drawn last; a frame laid out in rows grows
    // and shrinks to its rows; a card that comes onto the plane fades in. The
    // cards being carried, and a region being moved, follow the pointer
    // exactly, and a lens eases cards on its own.
    function stepMotion(now) {
      const d = state.drag
      const exact = d && (d.kind === 'moveRegion' || d.kind === 'resizeCard')
      const lensMoving = !!state.lens || !!(state.lensFrom && state.lensT < 1)
      let any = false
      for (const node of state.nodes) {
        const ref = node.ref
        const target = targetPos(node)
        if (!target) { state.moves.delete(ref); state.last.delete(ref); state.born.delete(ref); continue }
        any = true
        const last = state.last.get(ref)
        if (!last) {
          if (state.settled && !lensMoving) state.born.set(ref, now)
          state.last.set(ref, target)
          continue
        }
        if (lensMoving || exact || (d && d.carrying && d.carrying.has(ref))) {
          state.moves.delete(ref); state.last.set(ref, target); continue
        }
        let m = state.moves.get(ref)
        if (m) {
          if (m.to[0] !== target[0] || m.to[1] !== target[1]) { m.from = m.cur; m.to = target; m.t0 = now }
        } else if (Math.abs(last[0] - target[0]) > 0.5 || Math.abs(last[1] - target[1]) > 0.5) {
          m = { from: last, to: target, t0: now, cur: last }
          state.moves.set(ref, m)
        }
        if (m) {
          const k = Math.min(1, (now - m.t0) / MOVE_MS)
          m.cur = mix(m.from, m.to, ease(k))
          if (k >= 1) state.moves.delete(ref)
          state.last.set(ref, m.cur)
        } else state.last.set(ref, target)
      }
      for (const [ref, t0] of state.born) if (now - t0 >= APPEAR_MS) state.born.delete(ref)
      for (const r of Object.values(state.regions)) {
        const target = targetH(r)
        const last = state.regionLast.get(r.id)
        const resizing = d && d.kind === 'resizeRegion' && d.id === r.id
        if (last == null || resizing || lensMoving) { state.regionMoves.delete(r.id); state.regionLast.set(r.id, target); continue }
        let m = state.regionMoves.get(r.id)
        if (m) {
          if (m.to !== target) { m.from = m.cur; m.to = target; m.t0 = now }
        } else if (Math.abs(last - target) > 0.5) {
          m = { from: last, to: target, t0: now, cur: last }
          state.regionMoves.set(r.id, m)
        }
        if (m) {
          const k = Math.min(1, (now - m.t0) / MOVE_MS)
          m.cur = m.from + (m.to - m.from) * ease(k)
          if (k >= 1) state.regionMoves.delete(r.id)
          state.regionLast.set(r.id, m.cur)
        } else state.regionLast.set(r.id, target)
      }
      // A region's width slides too (a mind map outgrowing its frame, an Undo of a resize).
      for (const r of Object.values(state.regions)) {
        const target = targetW(r)
        const last = state.regionWLast.get(r.id)
        const resizing = d && d.kind === 'resizeRegion' && d.id === r.id
        if (last == null || resizing || lensMoving) { state.regionWMoves.delete(r.id); state.regionWLast.set(r.id, target); continue }
        let m = state.regionWMoves.get(r.id)
        if (m) {
          if (m.to !== target) { m.from = m.cur; m.to = target; m.t0 = now }
        } else if (Math.abs(last - target) > 0.5) {
          m = { from: last, to: target, t0: now, cur: last }
          state.regionWMoves.set(r.id, m)
        }
        if (m) {
          const k = Math.min(1, (now - m.t0) / MOVE_MS)
          m.cur = m.from + (m.to - m.from) * ease(k)
          if (k >= 1) state.regionWMoves.delete(r.id)
          state.regionWLast.set(r.id, m.cur)
        } else state.regionWLast.set(r.id, target)
      }
      for (const id of state.regionLast.keys()) if (!state.regions[id]) { state.regionLast.delete(id); state.regionMoves.delete(id); state.regionWLast.delete(id); state.regionWMoves.delete(id) }
      if (any) state.settled = true
      if (state.moves.size || state.born.size || state.regionMoves.size || state.regionWMoves.size) redraw()
    }
    // How far a card that just came onto the plane has faded in.
    function appear(node, now) {
      const t0 = state.exporting ? null : state.born.get(node.ref)
      return t0 == null ? 1 : ease(clamp((now - t0) / APPEAR_MS, 0, 1))
    }
    function isCarried(node) { const d = state.drag; return !!(d && d.carrying && d.carrying.has(node.ref)) }

    function draw() {
      const d = state.exporting ? 1 : window.devicePixelRatio || 1
      const W = viewW(), H = viewH()
      const now = performance.now()
      ctx.setTransform(d, 0, 0, d, 0, 0)
      ctx.fillStyle = state.colors.bg
      ctx.fillRect(0, 0, W, H)
      drawGrid(W, H)
      const L = level()
      const s = state.scale
      const c = state.colors
      ctx.textBaseline = 'top'
      state.badgeHits = []
      state.edgePills = []
      state.pageHits = []
      state.questionHits = []
      layoutFan(L)
      // Cards sliding to their spots move the ends of the arrows bundled between them.
      const sliding = state.moves.size > 0
      if (!state.exporting) stepMotion(now)
      if (sliding || state.moves.size) state.bundleCache = null
      if (state.ghostsDirty && state.proposals && ghostLayoutReady()) layoutGhosts(false)

      // Regions: faint tinted fields under everything (quieter while a card
      // is reviewed in place, dusty when what they hold is being forgotten).
      if (!state.lens) {
        ctx.globalAlpha = state.review ? 0.5 : 1
        for (const r of shownRegions()) {
          const [x, y] = toScreen(r.x, r.y)
          const w = r.w * s, h = r.h * s
          if (x > W || y > H || x + w < 0 || y + h < 0) continue
          // A region inside another fades away as it shrinks into its
          // parent's face.
          const tile = tileK(r)
          if (tile >= 1) continue
          ctx.globalAlpha = (state.review ? 0.5 : 1) * (1 - tile)
          const tint = r.color || REGION_TINTS[0]
          // The region the carried cards would land in answers them.
          const over = !!(state.drag && state.drag.overRegion === r.id)
          ctx.fillStyle = withAlpha(tint, (state.dark ? 0.12 : 0.07) + (over ? 0.06 : 0))
          roundRect(x, y, w, h, Math.max(8, 28 * s)); ctx.fill()
          ctx.strokeStyle = withAlpha(tint, state.selectedRegion === r.id ? 0.9 : over ? 0.7 : 0.22)
          ctx.lineWidth = state.selectedRegion === r.id || over ? 2 : 1
          if (state.selectedRegion === r.id) ctx.setLineDash([6, 4])
          else if (r.collapsed) ctx.setLineDash([3, 4])
          ctx.stroke(); ctx.setLineDash([])
          const mem = regionMemory(r)
          if (mem && mem.dusty) drawHatch(x, y, w, h, Math.max(8, 28 * s))
        }
        ctx.globalAlpha = 1
      }

      // Lens frames: soft fields with the group's or concept's name, a
      // concept's sentence under it in ForeverLM's voice, and the arrows
      // between concepts.
      if (state.lens && state.lensT > 0.2) {
        ctx.globalAlpha = Math.min(1, state.lensT)
        const frames = state.lens.frames || []
        for (const f of frames) {
          const [x, y] = toScreen(f.x, f.y)
          ctx.fillStyle = withAlpha(c.select, state.dark ? 0.10 : 0.05)
          roundRect(x, y, f.w * s, f.h * s, Math.max(8, 24 * s)); ctx.fill()
          const room = f.w * s - 28
          if (room < 30) continue
          const big = f.note ? Math.max(13, Math.min(20, 22 * s)) : 14
          ctx.fillStyle = c.select
          ctx.font = '600 ' + big + 'px ' + state.font
          const lines = wrapLines(f.label, ctx.font, room, 2)
          drawLines(lines, x + 14, y + 12, big + 4)
          if (f.note && L >= 1) {
            const noteFont = 'italic 12.5px ' + state.font
            const maxLines = Math.max(0, Math.floor((Math.min(f.h, 190) * s - 24 - lines.length * (big + 4)) / 17))
            if (maxLines > 0) {
              ctx.font = noteFont; ctx.fillStyle = c.ai
              drawLines(wrapLines('✦ ' + f.note, noteFont, room, Math.min(4, maxLines)), x + 14, y + 16 + lines.length * (big + 4), 17)
            }
          }
        }
        for (const l of state.lens.links || []) {
          const a = frames[l.from], b = frames[l.to]
          if (!a || !b) continue
          const ca = [a.x + a.w / 2, a.y + a.h / 2], cb = [b.x + b.w / 2, b.y + b.h / 2]
          const p = toScreen(...clipToRect(ca, cb, a.w / 2 + 10, a.h / 2 + 10))
          const q = toScreen(...clipToRect(cb, ca, b.w / 2 + 10, b.h / 2 + 10))
          ctx.strokeStyle = c.select; ctx.lineWidth = 2; ctx.lineCap = 'round'
          ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]); ctx.stroke(); ctx.lineCap = 'butt'
          const ang = Math.atan2(q[1] - p[1], q[0] - p[0])
          ctx.fillStyle = c.select
          ctx.beginPath(); ctx.moveTo(q[0], q[1])
          ctx.lineTo(q[0] - 12 * Math.cos(ang - 0.42), q[1] - 12 * Math.sin(ang - 0.42))
          ctx.lineTo(q[0] - 12 * Math.cos(ang + 0.42), q[1] - 12 * Math.sin(ang + 0.42))
          ctx.closePath(); ctx.fill()
          if (l.label && L >= 1) pill(l.label, (p[0] + q[0]) / 2, (p[1] + q[1]) / 2, true)
        }
        const ax = state.lens.axes
        if (ax) {
          ctx.strokeStyle = c.faint; ctx.lineWidth = 1.5
          const [x0, y0] = toScreen(ax.frame.x, ax.frame.y + ax.frame.h)
          const [x1] = toScreen(ax.frame.x + ax.frame.w, 0)
          const [, y1] = toScreen(0, ax.frame.y)
          ctx.beginPath(); ctx.moveTo(x0, y1); ctx.lineTo(x0, y0); ctx.lineTo(x1, y0); ctx.stroke()
          ctx.fillStyle = c.sub; ctx.font = '12px ' + state.font
          if (ax.x) {
            ctx.fillText(ax.x.low || '', x0, y0 + 8)
            const hw = ctx.measureText(ax.x.high || '').width
            ctx.fillText(ax.x.high || '', x1 - hw, y0 + 8)
            ctx.font = '600 13px ' + state.font; ctx.fillStyle = c.text
            const lw = ctx.measureText(ax.x.label || '').width
            ctx.fillText(ax.x.label || '', (x0 + x1) / 2 - lw / 2, y0 + 28)
          }
          if (ax.y) {
            ctx.save(); ctx.translate(x0 - 14, (y0 + y1) / 2); ctx.rotate(-Math.PI / 2)
            ctx.font = '600 13px ' + state.font; ctx.fillStyle = c.text
            const lw = ctx.measureText(ax.y.label || '').width
            ctx.fillText(ax.y.label || '', -lw / 2, -20)
            ctx.restore()
            ctx.font = '12px ' + state.font; ctx.fillStyle = c.sub
            ctx.fillText(ax.y.high || '', x0 + 8, y1)
            ctx.fillText(ax.y.low || '', x0 + 8, y0 - 20)
          }
        }
        ctx.globalAlpha = 1
      }

      // A focused card's relations: the graph, shown on focus only (and not
      // while a card is reviewed in place).
      if (state.selection.size === 1 && L > 0 && !state.review) {
        const ref = [...state.selection][0]
        const from = state.byRef.get(ref)
        const fp = from && pos(from)
        if (fp) {
          const [fw, fh] = sizeOf(from)
          ctx.strokeStyle = c.select; ctx.globalAlpha = 0.4; ctx.setLineDash([2, 5]); ctx.lineWidth = 1.2; ctx.lineCap = 'round'
          for (const l of state.links) {
            const other = l.a === ref ? l.b : l.b === ref ? l.a : null
            const node = other && state.byRef.get(other)
            const tp = node && inLens(node) && pos(node)
            if (!tp || state.fan.get(node.ref)?.idea === ref) continue
            const [tw, th] = sizeOf(node)
            const [ax, ay] = toScreen(fp[0] + fw / 2, fp[1] + fh / 2)
            const [bx, by] = toScreen(tp[0] + tw / 2, tp[1] + th / 2)
            ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(bx, by); ctx.stroke()
          }
          ctx.setLineDash([]); ctx.globalAlpha = 1; ctx.lineCap = 'butt'
        }
      }

      ctx.globalAlpha = state.review ? 0.3 : 1
      drawEvidenceThreads(L)
      drawEdges(L)
      ctx.globalAlpha = 1
      drawGhostLines(L)

      drawLandingSlot()

      // Cards: an Idea's evidence first, the placed cards lifted over it, and
      // the cards being carried over everything, lifted a little further.
      // While a card is reviewed in place, every other card is faint.
      const rank = (n) => isFanned(n) ? 0 : isCarried(n) ? 2 : 1
      const order = state.nodes.filter(shown).sort((a, b) => rank(a) - rank(b))
      const allowShadow = order.length < 500
      for (const node of order) {
        // A card's words are gone by the middle of the fold, before its
        // region's face writes its own (`drawRegionFace`): the two never
        // show at once, which read as text drawn over text.
        const fold = Math.min(1, folded(node) * 2)
        if (fold >= 1) continue
        ctx.save()
        ctx.globalAlpha = (1 - fold) * appear(node, now) * reviewDim(node) * focusDim(node)
        if (isFanned(node)) { drawEvidenceCard(node, L, W, H); ctx.restore(); continue }
        const lifted = isCarried(node)
        if (lifted && L > 0) {
          const p = pos(node)
          const [lw, lh] = sizeOf(node)
          const [cx, cy] = toScreen(p[0] + lw / 2, p[1] + lh / 2)
          ctx.translate(cx, cy); ctx.scale(1.03, 1.03); ctx.translate(-cx, -cy)
        }
        state.lifting = lifted
        const st = stackOf(node)
        if (st) {
          if (st.leader.ref === node.ref) drawStack(st, L, W, H)
          // A card folding into its series slides in under the stack.
          else if (state.moves.has(node.ref)) drawNode(node, L, W, H, allowShadow)
        } else drawNode(node, L, W, H, allowShadow)
        state.lifting = false
        ctx.restore()
      }
      ctx.globalAlpha = state.review ? 0.3 : 1
      drawOpenHeads(L)
      ctx.globalAlpha = 1
      drawGuides()
      // A card carried over an Idea is linked to it on the drop.
      const target = state.drag && state.drag.ideaTarget && state.byRef.get(state.drag.ideaTarget)
      const tp = target && pos(target)
      if (tp) {
        const [x, y] = toScreen(tp[0], tp[1])
        const [tw, th] = sizeOf(target)
        ctx.strokeStyle = c.ai; ctx.lineWidth = 2.5; ctx.setLineDash([6, 4])
        roundRect(x - 6, y - 6, tw * s + 12, th * s + 12, Math.max(6, 8 * s)); ctx.stroke(); ctx.setLineDash([])
        pill('Link as evidence', x + tw * s / 2, y - 22, true)
      }

      if (!state.lens) drawLabels(L, W, H)
      drawGhosts(L, W, H)
      drawPendingIdeas(L, W, H)
      drawCarriedCopy(L, W, H)
      drawReviewRing(now)
      drawHandles()
      drawConnectHandle()

      if (state.lasso) {
        ctx.strokeStyle = c.select; ctx.lineWidth = 1.5; ctx.setLineDash([5, 4])
        ctx.fillStyle = withAlpha(c.select, 0.06)
        ctx.beginPath()
        state.lasso.forEach((p, i) => i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1]))
        ctx.closePath(); ctx.fill(); ctx.stroke(); ctx.setLineDash([])
      }
      if (state.drag && state.drag.kind === 'marquee' && state.drag.moved) {
        const m = state.drag
        const x = Math.min(m.sx, m.px), y = Math.min(m.sy, m.py)
        const w = Math.abs(m.px - m.sx), h = Math.abs(m.py - m.sy)
        ctx.fillStyle = withAlpha(c.select, state.dark ? 0.12 : 0.07)
        ctx.fillRect(x, y, w, h)
        ctx.strokeStyle = withAlpha(c.select, 0.75); ctx.lineWidth = 1
        ctx.strokeRect(Math.round(x) + 0.5, Math.round(y) + 0.5, Math.round(w), Math.round(h))
      }
      if (state.drag && state.drag.kind === 'newRegion') {
        const r = state.drag.rect
        ctx.fillStyle = withAlpha(c.select, 0.06)
        ctx.strokeStyle = c.select; ctx.setLineDash([6, 4]); ctx.lineWidth = 1.5
        roundRect(r.x, r.y, r.w, r.h, 14); ctx.fill(); ctx.stroke(); ctx.setLineDash([])
      }
      if (state.drag && state.drag.kind === 'connect') {
        const [ax, ay] = toScreen(state.drag.fx, state.drag.fy)
        ctx.strokeStyle = c.select; ctx.lineWidth = 1.5; ctx.lineCap = 'round'
        ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(state.drag.px, state.drag.py); ctx.stroke(); ctx.lineCap = 'butt'
        const to = connectTarget(state.drag.px, state.drag.py, state.drag.from)
        if (to) drawConnectTarget(to)
      }
      if (state.exporting) return
      drawMinimap()
      positionEditor()
      positionEdgeBar()
      keepStickyPeek()
      reportCamera()
      if (state.review) postReviewAnchor(false)
    }

    // ---- Handles
    //
    // One selected card (placed in the open, not in a region laid out in rows,
    // not folded, from the middle zoom in) or a selected region shows eight
    // handles, corners and edge middles. A drag resizes: an edge changes the
    // width or the height, a corner both; a clip, page or picture keeps its
    // aspect from a corner.
    const HANDLE = 7
    const HANDLE_DIRS = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w']
    const HANDLE_CURSORS = { n: 'ns-resize', s: 'ns-resize', e: 'ew-resize', w: 'ew-resize', nw: 'nwse-resize', se: 'nwse-resize', ne: 'nesw-resize', sw: 'nesw-resize' }
    // The region a placed card is in, when the learner locked it.
    function lockedRegionOf(ref) {
      const id = stackLayout().innermost.get(ref)
      const r = id && state.regions[id]
      return r && r.locked ? r : null
    }
    function resizableCard() {
      if (state.selection.size !== 1 || state.lens || state.review || state.selectedRegion || state.selectedEdge || state.ghostSelected) return null
      if (level() < 2 || state.editor || state.exporting) return null
      const ref = [...state.selection][0]
      const node = state.byRef.get(ref)
      if (!node || !state.placements[ref] || isFoldedCard(node) || flowed(node) || isFanned(node) || stackOf(node)) return null
      // A mind map's node is as big as its words: a size of its own would make it a card.
      if (hiddenByFold(ref) || lockedRegionOf(ref) || mindInfo(node)) return null
      const p = pos(node)
      return p ? { node, p } : null
    }
    function computeHandles() {
      const out = []
      const box = (x, y, w, h, kind, id) => {
        for (const dir of HANDLE_DIRS) {
          const hx = dir.includes('w') ? x : dir.includes('e') ? x + w : x + w / 2
          const hy = dir.includes('n') ? y : dir.includes('s') ? y + h : y + h / 2
          out.push({ kind, id, dir, x: hx, y: hy })
        }
      }
      const rc = resizableCard()
      if (rc) {
        const [w, h] = sizeOf(rc.node)
        const [x, y] = toScreen(rc.p[0], rc.p[1])
        box(x, y, w * state.scale, h * state.scale, 'card', rc.node.ref)
      }
      const r = state.selectedRegion && state.regions[state.selectedRegion]
      if (r && !r.collapsed && !r.locked && !state.lens && !state.review && !state.exporting && foldK() < 0.5 && tileK(r) < 1 && !hidden().regions.has(r.id)) {
        const sr = shownRegions().find(s => s.id === r.id) || r
        const [x, y] = toScreen(sr.x, sr.y)
        box(x, y, sr.w * state.scale, sr.h * state.scale, 'region', r.id)
      }
      return out
    }
    function drawHandles() {
      state.handles = []
      if (state.exporting) return
      const d = state.drag
      if (d && (d.kind === 'cards' || d.kind === 'moveRegion') && d.moved) return
      const list = computeHandles()
      if (!list.length) return
      const c = state.colors
      ctx.fillStyle = c.select; ctx.strokeStyle = c.card; ctx.lineWidth = 1
      for (const h of list) {
        ctx.beginPath(); ctx.rect(Math.round(h.x - HANDLE / 2) + 0.5, Math.round(h.y - HANDLE / 2) + 0.5, HANDLE, HANDLE)
        ctx.fill(); ctx.stroke()
      }
      state.handles = list.map(h => ({ kind: h.kind, id: h.id, dir: h.dir, x: round(h.x - HANDLE / 2), y: round(h.y - HANDLE / 2), w: HANDLE, h: HANDLE }))
    }
    function hitHandle(px, py) {
      for (const h of computeHandles()) {
        if (Math.abs(px - h.x) <= HANDLE / 2 + 4 && Math.abs(py - h.y) <= HANDLE / 2 + 4) return h
      }
      return null
    }
    // A clip, page, picture or page face's foot (its name and note under the
    // picture) and the room for the words about it.
    function footOf(node, width) {
      let foot = 0
      if (node.kind === 'clip' || node.kind === 'page') foot = CLIP_FOOT + (node.caption ? CAPTION_ROOM : 0)
      else if (isPageFace(node)) foot = PAGE_FOOT
      return foot + (isFoldedCard(node) ? 0 : annotationHeight(annotationOf(node), width == null ? cardW(node) : width))
    }
    // Starts a resize of the card or region a handle belongs to.
    function beginResize(h, px, py) {
      if (h.kind === 'region') {
        const r = state.regions[h.id]
        state.drag = { kind: 'resizeRegion', id: r.id, dir: h.dir, px, py, x: r.x, y: r.y, w: r.w, h: r.h, moved: false, members: stackLayout().members.get(r.id) || null }
        return
      }
      const node = state.byRef.get(h.id)
      const p = state.placements[h.id]
      const [w0, h0] = [cardW(node), cardH(node)]
      const aspect = node.kind === 'clip' || node.kind === 'page' || node.kind === 'picture' || isPageFace(node)
      state.drag = { kind: 'resizeCard', ref: h.id, dir: h.dir, px, py, x: p.x, y: p.y, w: w0, h: h0, was: Object.assign({}, p), aspect, ratio: aspect ? (h0 - footOf(node)) / w0 : 0, moved: false }
    }
    // The resize under way, for the pointer at world offset (dx, dy).
    function resizeCardTo(d, dx, dy) {
      let x = d.x, y = d.y, w = d.w, h = d.h
      const east = d.dir.includes('e'), west = d.dir.includes('w'), north = d.dir.includes('n'), south = d.dir.includes('s')
      if (east) w = d.w + dx
      if (west) w = d.w - dx
      w = clamp(w, MIN_CARD_W, MAX_CARD_W)
      if (west) x = d.x + d.w - w
      const corner = (east || west) && (north || south)
      if (d.aspect && corner) {
        // The picture keeps its shape; the foot and the words about it take what they need at the new width.
        h = w * d.ratio + footOf(state.byRef.get(d.ref), w)
      } else {
        if (south) h = d.h + dy
        if (north) h = d.h - dy
        h = Math.max(MIN_CARD_H, h)
      }
      if (north) y = d.y + d.h - h
      const p = state.placements[d.ref]
      if (!p) return
      const next = Object.assign({}, p, { x, y })
      if (east || west) next.w = w
      if (north || south || (d.aspect && corner)) next.h = h
      state.placements[d.ref] = next
    }

    // ---- The connect handle
    //
    // Hovering a placed card from the middle zoom in shows a ring with a dot
    // just off its right middle; dragging from it is the Arrow tool for that
    // drag, and letting go over a card or a region's name draws an arrow there.
    const CONNECT_R = 7
    // On a mind map's node it is a + in a circle, in the node's branch colour,
    // that adds a child (`addTreeChild`), in place of the ring.
    function connectHandleOf(ref) {
      if (state.lens || state.review || state.exporting || level() < 2) return null
      const node = state.byRef.get(ref)
      if (!node || !isPlaced(node) || isFanned(node) || stackOf(node) || hiddenByFold(ref)) return null
      const p = pos(node)
      if (!p) return null
      const [w, h] = sizeOf(node)
      const [x, y] = toScreen(p[0], p[1])
      const mind = mindInfo(node)
      return { ref, x: x + w * state.scale + 14, y: y + h * state.scale / 2, wx: p[0] + w, wy: p[1] + h / 2, plus: !!mind, tint: mind ? nodeTint(node, mind) : null }
    }
    // The cards whose handle shows: the one under the pointer, and a mind map's node that is selected.
    function handleRefs() {
      const refs = state.hover ? [state.hover] : []
      if (state.selection.size === 1) {
        const ref = [...state.selection][0]
        if (!refs.includes(ref) && mindInfo(state.byRef.get(ref))) refs.push(ref)
      }
      return refs
    }
    function hitConnectHandle(px, py) {
      for (const ref of handleRefs()) {
        const h = connectHandleOf(ref)
        if (h && Math.hypot(px - h.x, py - h.y) <= (h.plus ? BADGE_R : CONNECT_R) + 5) return h
      }
      return null
    }
    function drawConnectHandle() {
      const d = state.drag
      if (state.exporting || (d && !(d.kind === 'connect' && d.viaHandle))) return
      for (const ref of d ? [d.from] : handleRefs()) {
        const h = ref && connectHandleOf(ref)
        if (h) drawHandle(h)
      }
    }
    function drawHandle(h) {
      const c = state.colors
      const r = h.plus ? BADGE_R : CONNECT_R
      ctx.save()
      ctx.shadowColor = c.shadow; ctx.shadowBlur = 5; ctx.shadowOffsetY = 1
      ctx.fillStyle = c.card
      ctx.beginPath(); ctx.arc(h.x, h.y, r, 0, Math.PI * 2); ctx.fill()
      ctx.restore()
      ctx.strokeStyle = h.plus ? h.tint : c.select; ctx.lineWidth = 1.5
      ctx.beginPath(); ctx.arc(h.x, h.y, r, 0, Math.PI * 2); ctx.stroke()
      if (h.plus) {
        ctx.lineWidth = 1.7; ctx.lineCap = 'round'
        ctx.beginPath(); ctx.moveTo(h.x - 3.6, h.y); ctx.lineTo(h.x + 3.6, h.y); ctx.moveTo(h.x, h.y - 3.6); ctx.lineTo(h.x, h.y + 3.6); ctx.stroke()
        ctx.lineCap = 'butt'
      } else {
        ctx.fillStyle = c.select
        ctx.beginPath(); ctx.arc(h.x, h.y, 2.4, 0, Math.PI * 2); ctx.fill()
      }
    }
    // The + on a node: a child of it, written in place (the host places it and
    // opens it, as it does for Tab).
    function addTreeChild(ref) {
      const node = state.byRef.get(ref), p = state.placements[ref], mind = mindInfo(node)
      if (!node || !p || !mind) return
      host.post('ideaRequested', { parentRef: ref, title: '', edit: true, x: round(p.x + cardW(node) + TREE_COL), y: round(p.y), regionID: mind.regionID })
    }
    // What a connecting drag would join to: a card, else a region's name or face.
    function connectTarget(px, py, from) {
      const node = hitNode(px, py)
      if (node) return node.ref !== from ? node.ref : null
      const region = hitRegion(px, py)
      return region && ('region:' + region.region.id) !== from ? 'region:' + region.region.id : null
    }
    function drawConnectTarget(ref) {
      const r = endRect(ref)
      if (!r) return
      const c = state.colors
      const [x, y] = toScreen(r.x, r.y)
      ctx.strokeStyle = c.select; ctx.lineWidth = 2.5; ctx.setLineDash([6, 4])
      roundRect(x - 5, y - 5, r.w * state.scale + 10, r.h * state.scale + 10, Math.max(6, 12 * state.scale) + 4); ctx.stroke(); ctx.setLineDash([])
    }

    // ---- An arrow's label, and its toolbar
    function openEdgeLabelEditor(id) {
      const e = state.edges[id]
      if (!e || state.lens || state.review) return
      const place = () => {
        const cur = state.edges[id]
        const path = cur && edgePath(cur)
        if (!path) return null
        const [mx, my] = toScreen(path.mid[0], path.mid[1])
        const pl = state.edgePills.find(p => p.id === id)
        const w = pl ? pl.w : 120
        return { x: mx - w / 2, y: my - 11, w, h: 22 }
      }
      selectEdge(id)
      openLineEditor({
        kind: 'edge', id, text: e.label || '', placeholder: 'Label', place, center: true, minW: 140,
        font: '500 12px ' + state.font, color: state.colors.text,
        commit: (text) => {
          const cur = state.edges[id]
          if (!cur || text === (cur.label || '')) return
          cur.label = text
          host.post('edgeChanged', { id, label: text })
          invalidate()
        },
      })
    }
    // The selected arrow's toolbar, in HTML above its middle: route, heads,
    // dashed, the eight colours, delete. Each posts edgeChanged (or edgeDeleted).
    const ICONS = {
      curve: '<path d="M2.5 12.5 C6 2.5 10 15 13.5 4" />',
      straight: '<path d="M2.5 13 L13.5 3.5" />',
      elbow: '<path d="M2.5 12.5 H8 V4 H13.5" />',
      end: '<path d="M2 8 H12 M9 4.8 L12.4 8 L9 11.2" />',
      both: '<path d="M3.6 8 H12.4 M6.4 4.8 L3 8 L6.4 11.2 M9.6 4.8 L13 8 L9.6 11.2" />',
      none: '<path d="M2.5 8 H13.5" />',
      dashed: '<path d="M2 8 H4.6 M6.7 8 H9.3 M11.4 8 H14" />',
      trash: '<path d="M3.5 4.5 H12.5 M6 4.5 V3 H10 V4.5 M4.7 4.5 L5.3 13 H10.7 L11.3 4.5" />',
    }
    const svg = (name) => '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICONS[name] + '</svg>'
    const edgeBar = document.createElement('div')
    edgeBar.className = 'map-edge-bar'
    edgeBar.setAttribute('role', 'toolbar')
    edgeBar.setAttribute('aria-label', 'Arrow')
    edgeBar.innerHTML =
      ['curve', 'straight', 'elbow'].map(r => '<button type="button" tabindex="-1" data-route="' + r + '" title="' + r[0].toUpperCase() + r.slice(1) + '">' + svg(r) + '</button>').join('') +
      '<i></i>' +
      [['end', 'Head at the end'], ['both', 'Heads at both ends'], ['none', 'No head']].map(([h, t]) => '<button type="button" tabindex="-1" data-heads="' + h + '" title="' + t + '">' + svg(h) + '</button>').join('') +
      '<i></i><button type="button" tabindex="-1" data-dashed title="Dashed">' + svg('dashed') + '</button><i></i>' +
      STANCE_KEYS.map(k => '<button type="button" tabindex="-1" class="stance" data-stance="' + k + '" title="' + (k === 'supports' ? 'Supports (for)' : 'Contradicts (against)') + '">' + (k === 'supports' ? 'For' : 'Against') + '</button>').join('') + '<i></i>' +
      REGION_TINTS.map(t => '<button type="button" tabindex="-1" class="dot" data-color="' + t + '" title="Colour" style="--dot:' + t + '"></button>').join('') +
      '<i></i><button type="button" tabindex="-1" data-delete title="Delete arrow">' + svg('trash') + '</button>'
    document.body.appendChild(edgeBar)
    edgeBar.addEventListener('mousedown', (e) => e.preventDefault())
    edgeBar.addEventListener('wheel', onWheel, { passive: false })
    edgeBar.addEventListener('click', (ev) => {
      const b = ev.target.closest('button')
      const e = state.selectedEdge && state.edges[state.selectedEdge]
      if (!b || !e) return
      ev.preventDefault()
      if (b.hasAttribute('data-delete')) { host.post('edgeDeleted', { id: e.id }); return }
      // A default is cleared (null), never stored: the stored row stays small.
      const change = {}
      if (b.dataset.route) change.route = b.dataset.route === 'curve' ? null : b.dataset.route
      else if (b.dataset.heads) change.heads = b.dataset.heads === 'end' ? null : b.dataset.heads
      else if (b.hasAttribute('data-dashed')) change.dashed = e.dashed ? null : true
      else if (b.dataset.stance) change.stance = e.stance === b.dataset.stance ? null : b.dataset.stance
      else if (b.dataset.color) change.color = e.color === b.dataset.color ? null : b.dataset.color
      for (const [k, v] of Object.entries(change)) { if (v == null || v === false) delete e[k]; else e[k] = v }
      host.post('edgeChanged', Object.assign({ id: e.id }, change))
      state.edgeBarKey = null
      invalidate()
    })
    function positionEdgeBar() {
      const e = state.selectedEdge && state.edges[state.selectedEdge]
      const d = state.drag
      const path = e && !state.exporting && !state.lens && !state.review && !(state.editor && state.editor.kind === 'edge') && level() >= 1 && !(d && d.kind !== 'pan') && edgeShown(e) ? edgePath(e) : null
      if (!path) { if (state.edgeBarKey !== 'hidden') { edgeBar.classList.remove('shown'); state.edgeBarKey = 'hidden' } return }
      const key = [e.id, e.route || 'curve', e.heads || 'end', !!e.dashed, e.color || '', e.stance || '', !!e.tree].join('|')
      if (state.edgeBarKey !== key) {
        state.edgeBarKey = key
        edgeBar.classList.add('shown')
        edgeBar.classList.toggle('tree', !!e.tree)
        for (const b of edgeBar.querySelectorAll('button')) {
          const on = (b.dataset.route && b.dataset.route === (e.route || 'curve')) || (b.dataset.heads && b.dataset.heads === (e.heads || 'end')) ||
            (b.hasAttribute('data-dashed') && !!e.dashed) || (b.dataset.stance && b.dataset.stance === e.stance) || (b.dataset.color && b.dataset.color === e.color)
          b.classList.toggle('on', !!on)
        }
      }
      const [mx, my] = toScreen(path.mid[0], path.mid[1])
      const bw = edgeBar.offsetWidth || 300, bh = edgeBar.offsetHeight || 34
      let x = clamp(mx - bw / 2, 8, Math.max(8, viewW() - bw - 8))
      let y = my - bh - (e.label && level() >= 2 ? 26 : 16)
      if (y < 8) y = my + 18
      edgeBar.style.transform = 'translate(' + Math.round(x) + 'px,' + Math.round(clamp(y, 8, Math.max(8, viewH() - bh - 8))) + 'px)'
    }

    // Where the carried cards will land in a region laid out in rows: a soft
    // slot the other cards have made room for.
    function drawLandingSlot() {
      const d = state.drag
      if (!d || d.kind !== 'cards' || !d.moved || !d.preview || d.ideaTarget || !d.starts.length) return
      const p = d.preview.pos.get(d.starts[0].ref)
      if (!p) return
      const c = state.colors
      const [x, y] = toScreen(p[0], p[1])
      const [lw, lh] = sizeOf(state.byRef.get(d.starts[0].ref))
      const w = lw * state.scale, h = lh * state.scale
      ctx.fillStyle = withAlpha(c.select, state.dark ? 0.14 : 0.07)
      ctx.strokeStyle = withAlpha(c.select, 0.55); ctx.lineWidth = 1.5; ctx.setLineDash([6, 5])
      roundRect(x, y, w, h, Math.max(2, 12 * state.scale)); ctx.fill(); ctx.stroke(); ctx.setLineDash([])
    }

    // The lines free cards were lined up on while carried.
    function drawGuides() {
      const d = state.drag
      if (!d || !d.guides || !d.guides.length) return
      ctx.strokeStyle = GUIDE; ctx.lineWidth = 1
      for (const g of d.guides) {
        const [x1, y1] = toScreen(g.x1, g.y1), [x2, y2] = toScreen(g.x2, g.y2)
        ctx.beginPath()
        if (g.x1 === g.x2) { ctx.moveTo(Math.round(x1) + 0.5, y1); ctx.lineTo(Math.round(x2) + 0.5, y2) }
        else { ctx.moveTo(x1, Math.round(y1) + 0.5); ctx.lineTo(x2, Math.round(y2) + 0.5) }
        ctx.stroke()
      }
    }

    // ---- Extending to another display
    //
    // While the Map is extended to a second display, two pages show one
    // plane (docs/knowledge-map-design.md, "Extending to another display").
    // Every camera move here goes to the host, which derives the other
    // window's camera from it; a camera the host sets is not sent back.

    function sameCamera(a, b) { return !!a && !!b && a.scale === b.scale && a.ox === b.ox && a.oy === b.oy }
    function reportCamera() {
      if (!state.link) return
      const cam = { scale: state.scale, ox: state.ox, oy: state.oy }
      if (sameCamera(cam, state.lastCam)) return
      state.lastCam = cam
      host.post('camera', cam)
    }

    // A dragged card's pointer past the edge shared with the other window:
    // the desk between the two views is skipped, and while the pointer
    // crosses it the card waits at the edge, so a card carried across lands
    // under the pointer in the other window.
    function linkedPoint(px, py) {
      const k = state.link
      if (!k) return [px, py]
      const W = viewW(), H = viewH()
      if (k.edge === 'right' && px > W) return [px <= W + k.gap ? W : px - k.gap, py]
      if (k.edge === 'left' && px < 0) return [px >= -k.gap ? 0 : px + k.gap, py]
      if (k.edge === 'bottom' && py > H) return [px, py <= H + k.gap ? H : py - k.gap]
      if (k.edge === 'top' && py < 0) return [px, py >= -k.gap ? 0 : py + k.gap]
      return [px, py]
    }

    // The drag in progress, for the other window to draw as it goes.
    function postDragPreview(d) {
      if (!state.link) return
      let items = []
      if (d.kind === 'cards' && d.moved) items = d.starts.map(st => state.placements[st.ref] && { ref: st.ref, x: state.placements[st.ref].x, y: state.placements[st.ref].y })
      else if (d.kind === 'moveRegion') items = d.cards.map(st => state.placements[st.ref] && { ref: st.ref, x: state.placements[st.ref].x, y: state.placements[st.ref].y })
      else if (d.kind !== 'resizeRegion') return
      const region = (d.kind === 'moveRegion' || d.kind === 'resizeRegion') && state.regions[d.id] ? cleanRegion(state.regions[d.id]) : null
      d.previewed = true
      host.post('dragPreview', { items: items.filter(Boolean), region })
    }

    function clearPreview() {
      clearTimeout(state.previewTimer)
      if (!state.preview && !state.previewRegion) return
      state.preview = null
      state.previewRegion = null
      invalidate()
    }

    // Names over everything: the learner's regions, with the model's summary
    // of a region under its name when one has been written (in its own,
    // quieter voice).
    function drawLabels(L, W, H) {
      const c = state.colors
      const s = state.scale
      state.labelHits = []
      state.chevronHits = []
      state.lockHits = []
      // A label fits the field it names: its width is the field's width on
      // screen, its size steps down as the field shrinks, and the lines that
      // do not fit are left out rather than spilling onto a neighbour.
      // The count line is the region's cards, or with the Memory layer on,
      // how the kept cards about them stand, after a pip of their colour.
      const label = (x, y, w, h, title, titleColor, count, gist) => {
        if (w < 64 || h < 22) return
        const maxW = w - 24
        const big = w >= 170 ? (L === 0 ? 15 : 14) : 12
        const titleFont = '600 ' + big + 'px ' + state.font
        const titleLines = wrapLines(title, titleFont, maxW, 2)
        const items = [{ font: titleFont, color: titleColor, lh: big + 4, lines: titleLines }]
        let height = titleLines.length * (big + 4)
        if (count && h > height + 30) {
          const countFont = '12px ' + state.font
          const indent = count.pip ? 11 : 0
          const lines = wrapLines(count.text, countFont, maxW - indent, 1)
          items.push({ font: countFont, color: c.faint, lh: 15, lines, gap: 2, pip: count.pip, indent })
          height += 17
        }
        if (gist && w > 150 && h > height + 40) {
          const gistFont = 'italic 12.5px ' + state.font
          const room = Math.max(1, Math.min(L === 0 ? 2 : 4, Math.floor((h - height - 20) / 17)))
          items.push({ font: gistFont, color: c.ai, lh: 17, lines: wrapLines('✦ ' + gist, gistFont, Math.min(maxW, 440), room), gap: 4 })
        }
        let width = 0, total = 0
        for (const it of items) {
          ctx.font = it.font
          for (const l of it.lines) width = Math.max(width, ctx.measureText(l).width + (it.indent || 0))
          total += it.lines.length * it.lh + (it.gap || 0)
        }
        if (L === 0) {
          ctx.fillStyle = withAlpha(c.bg, 0.9)
          roundRect(x - 6, y - 5, width + 12, total + 10, 8); ctx.fill()
        }
        // The words on the plate, then the plate's bounds, which the name's
        // hit test reads (returning those first left the plate empty).
        let cy = y
        for (const it of items) {
          cy += it.gap || 0
          if (it.pip) drawPip(x + 4, cy + 7.5, it.pip)
          ctx.font = it.font; ctx.fillStyle = it.color
          drawLines(it.lines, x + (it.indent || 0), cy, it.lh)
          cy += it.lines.length * it.lh
        }
        return { x: x - 6, y: y - 5, w: width + 12, h: total + 10 }
      }
      // Names and counts are where-you-are cues in a review in place, so they
      // stay readable, a little quieter.
      const dim = state.review ? 0.6 : 1
      for (const r of shownRegions()) {
        const [x, y] = toScreen(r.x, r.y)
        const w = r.w * s, h = r.h * s
        if (x > W || y > H || x + w < 0 || y + h < 0) continue
        const refs = refsInRegion(r)
        const gist = state.summaries.regions[r.id]
        const nb = notebookOf(r)
        const mem = regionMemory(r)
        // A region shrunk away into its parent's face is not named.
        const tile = tileK(r)
        if (tile >= 1) continue
        // Every region folds into its face once its cards are too small to read.
        const fold = foldK()
        if (fold > 0) {
          const hit = drawRegionFace(r, nb, refs, gist, x, y, w, h, fold * dim * (1 - tile), mem, clamp(fold * 2 - 1, 0, 1) * dim * (1 - tile))
          if (hit) state.labelHits.push(Object.assign({ id: r.id }, hit))
          if (fold >= 1) continue
        }
        // The name above the frame stays whole while the cards fade, and
        // hands over to the face's own words as they come in (the second
        // half of the fold), so the region is never named only faintly.
        ctx.save(); ctx.globalAlpha = (1 - clamp(fold * 2 - 1, 0, 1)) * dim
        if (L === 0) {
          const count = mem && mem.cards ? { text: memoryText(mem), pip: memoryTone(mem) } : { text: countWord(refs) }
          const hit = label(x + 14, y + 12, w - 14, h - 12, regionName(r), r.color || REGION_TINTS[0], count, gist ? gist.short : null)
          if (hit) state.labelHits.push(Object.assign({ id: r.id }, hit))
          ctx.restore()
          continue
        }
        // Closer in, the name and the summary stay in the band above the
        // region's top row of cards and never run over a card.
        let top = Infinity
        for (const ref of refs) { const n = state.byRef.get(ref); const p = n && pos(n); if (p) top = Math.min(top, p[1]) }
        const band = (isFinite(top) ? top - r.y : r.h) * s - 10
        const hit = regionHeader(x + 14, y + 12, w - 28, band - 12, regionName(r), r.color || REGION_TINTS[0],
          refs.length ? countWord(refs) : 0, gist && L <= 2 ? (gist.long || gist.short) : null, mem, r)
        if (hit) {
          state.labelHits.push(Object.assign({ id: r.id }, hit))
          if (hit.chev) state.chevronHits.push(Object.assign({ id: r.id }, hit.chev))
          if (hit.lock) state.lockHits.push(Object.assign({ id: r.id }, hit.lock))
        }
        ctx.restore()
      }
    }

    // A region folded into its face, for the bigger story. A notebook's
    // frame reads as the notebook: its name, what it holds, and its takeaways
    // (the Canvas Summaries model's, marked as ForeverLM's), or its own
    // description until those are written. Any other region reads as what
    // the learner wrote in it: its name, what it holds, and its own Ideas top
    // to bottom (the Ideas of the regions inside it when it has none of its
    // own), or the model's gist when there are no Ideas at all. Drawn over
    // its cards, fading in as they fade out. While the regions inside it are
    // still tiles wide enough to read, only its name and counts show; as they
    // shrink away, its own lines take their place. With the Memory layer on
    // it says how the kept cards about it stand, and gathers dust when they
    // are being forgotten.
    function drawRegionFace(r, nb, refs, gist, x, y, w, h, k, mem, wordsK = k) {
      const c = state.colors
      const tint = r.color || REGION_TINTS[0]
      if (w < 40 || h < 18) return null
      const kids = childRegions(r.id)
      // The body's lines show as the tiles inside fade: 1 with none inside.
      const bodyK = kids.length ? Math.min(...kids.map(tileK)) : 1
      ctx.save()
      ctx.globalAlpha = k
      const radius = Math.max(8, 28 * state.scale)
      ctx.fillStyle = c.bg
      roundRect(x, y, w, h, radius); ctx.fill()
      ctx.fillStyle = withAlpha(tint, state.dark ? 0.22 : 0.13)
      ctx.fill()
      ctx.strokeStyle = withAlpha(tint, state.selectedRegion === r.id ? 0.9 : 0.45)
      ctx.lineWidth = state.selectedRegion === r.id ? 2 : 1.2
      ctx.stroke()
      if (mem && mem.dusty) drawHatch(x, y, w, h, radius)
      ctx.save(); roundRect(x, y, w, h, radius); ctx.clip()
      // The face's words come in once its cards' are gone (the second half
      // of the fold); its plate fades in all the way.
      ctx.globalAlpha = wordsK
      const pad = Math.max(10, Math.min(18, h * 0.12))
      const maxW = w - pad * 2
      const big = w >= 260 ? 17 : w >= 140 ? 14 : 12
      let cy = y + pad
      // A paper's region reads as the paper's banner: its picture at the
      // left, its name in the text colour, then who, where and when.
      const paper = nb ? null : paperOf(r)
      const thumb = paperThumb(paper)
      const thumbW = thumb && w >= 220 && h >= 90 ? Math.min(44, h * 0.3) : 0
      const thumbH = thumbW * 1.3
      const tx = x + pad + (thumbW ? thumbW + 12 : 0), tMaxW = maxW - (thumbW ? thumbW + 12 : 0)
      if (thumbW) drawPaperThumb(thumb, x + pad, cy + 2, thumbW, thumbH)
      ctx.font = '600 ' + big + 'px ' + state.font
      ctx.fillStyle = paper ? c.text : tint
      const titleLines = wrapLines(regionName(r), ctx.font, tMaxW, h > 80 ? 2 : 1)
      drawLines(titleLines, tx, cy, big + 4)
      if (r.locked && titleLines.length) drawLock(tx + ctx.measureText(titleLines[0]).width + 6, cy + (big + 4) / 2, c.faint)
      cy += titleLines.length * (big + 4) + 2
      if (paper && paper.byline && y + h - cy > 30) {
        ctx.font = '12.5px ' + state.font; ctx.fillStyle = c.sub
        drawLines(wrapLines(paper.byline, ctx.font, tMaxW, 1), tx, cy, 16)
        cy += 18
      }
      let counts
      if (nb) {
        const docs = refs.filter(ref => { const n = state.byRef.get(ref); return n && n.kind === 'doc' }).length
        const sources = refs.length - docs
        counts = [sources ? sources + (sources === 1 ? ' source' : ' sources') : '', docs ? docs + (docs === 1 ? ' Page' : ' Pages') : ''].filter(Boolean).join(' · ')
      } else {
        counts = [refs.length ? refs.length + (refs.length === 1 ? ' card' : ' cards') : '', kids.length ? kids.length + (kids.length === 1 ? ' region' : ' regions') : ''].filter(Boolean).join(' · ')
      }
      if (counts && y + h - cy > 30) {
        ctx.font = '12px ' + state.font; ctx.fillStyle = c.faint
        ctx.fillText(counts, tx, cy)
        cy += 18
      }
      // What follows the banner starts under the picture too.
      if (thumbW) cy = Math.max(cy, y + pad + 2 + thumbH + 8)
      if (mem && mem.cards && y + h - cy > 30) {
        ctx.font = '12px ' + state.font
        drawPip(x + pad + 4, cy + 7.5, memoryTone(mem))
        ctx.fillStyle = c.faint
        drawLines(wrapLines(memoryText(mem), ctx.font, maxW - 11, 1), x + pad + 11, cy, 15)
        cy += 18
      }
      const lineH = 17
      // A notebook's frame: the model's takeaways. Any other region: the
      // learner's own Ideas, in their words and without the model's mark.
      const takeaways = nb && gist && gist.takeaways && gist.takeaways.length ? gist.takeaways : null
      const ideas = nb ? [] : faceLines(r)
      const bullets = takeaways || (ideas.length ? ideas : null)
      if (bodyK > 0) ctx.globalAlpha = wordsK * bodyK
      if (bullets && bodyK > 0) {
        if (takeaways) {
          ctx.font = '600 10.5px ' + state.font; ctx.fillStyle = c.ai
          if (y + h - cy > 40) { ctx.fillText('✦ TAKEAWAYS', x + pad, cy + 2); cy += 17 }
        }
        const font = '12.5px ' + state.font
        for (const t of bullets) {
          const room = Math.floor((y + h - pad * 0.6 - cy) / lineH)
          if (room < 1) break
          const lines = wrapLines(t, font, maxW - 12, Math.min(2, room))
          ctx.font = font; ctx.fillStyle = takeaways ? c.ai : tint
          ctx.fillText('•', x + pad, cy)
          ctx.fillStyle = c.text
          drawLines(lines, x + pad + 12, cy, lineH)
          cy += lines.length * lineH + 3
        }
      } else if (bodyK > 0) {
        const own = nb ? nb.summary : ''
        const text = own || (gist ? '✦ ' + (gist.long || gist.short) : '')
        const room = Math.floor((y + h - pad * 0.6 - cy) / lineH)
        if (text && room > 0) {
          const font = (own ? '' : 'italic ') + '12.5px ' + state.font
          ctx.font = font; ctx.fillStyle = own ? c.sub : c.ai
          drawLines(wrapLines(text, font, maxW, Math.min(4, room)), x + pad, cy, lineH)
        } else if (room > 0) {
          // Nothing written about it yet: what it holds, by name, quietly,
          // so a folded region is never an empty box.
          const font = '12.5px ' + state.font
          ctx.font = font
          // A paper's pages are one line: the paper, and how many.
          const names = [], from = new Map()
          for (const ref of refs) {
            const n = state.byRef.get(ref)
            if (!n || !n.title) continue
            if (n.kind !== 'page' || !n.sub) { names.push({ text: n.title, n: 1 }); continue }
            const key = n.src || n.sub
            if (!from.has(key)) { from.set(key, { text: n.sub, n: 0, page: n.title }); names.push(from.get(key)) }
            from.get(key).n += 1
          }
          let left = room
          for (let i = 0; i < names.length && left >= 1; i++) {
            ctx.fillStyle = c.faint
            // The last line says how many more there are, rather than one more name.
            if (left === 1 && i < names.length - 1) {
              ctx.fillText((names.length - i) + ' more', x + pad + 12, cy)
              break
            }
            const it = names[i]
            const text = it.page ? it.text + ' · ' + (it.n > 1 ? it.n + ' pages' : it.page) : it.text
            ctx.fillText('·', x + pad + 2, cy)
            ctx.fillStyle = c.sub
            drawLines(wrapLines(text, font, maxW - 12, 1), x + pad + 12, cy, lineH)
            cy += lineH; left -= 1
          }
        }
      }
      ctx.restore()
      ctx.restore()
      return { x, y, w, h }
    }

    // A region's name, how many cards it holds (with the Memory layer on, how
    // the kept cards about them stand), and its summary, laid out to fit `h`
    // pixels: the summary gives way first, then the count.
    function regionHeader(x, y, w, h, title, color, count, gist, mem, region) {
      const c = state.colors
      if (w < 60) return
      // The name, its count and the summary sit above the frame, as a frame's
      // name does, so they never compete with the cards for room: the block
      // ends just above the frame's edge and grows upward.
      const big = 14
      const titleFont = '600 ' + big + 'px ' + state.font
      const gistFont = '12.5px ' + state.font
      const gistLines = gist ? wrapLines('✦ ' + gist, gistFont, Math.min(w + 14, 680), 2) : []
      const left = x - 14
      // The name starts after the disclosure triangle that folds the region up.
      const lx0 = left + (region ? CHEV : 0)
      // A paper's region reads as the paper's banner: its picture, its name,
      // then who, where and when.
      const paper = region ? paperOf(region) : null
      const thumb = paperThumb(paper)
      const thumbW = thumb ? 30 : 0
      const lx = lx0 + (thumbW ? thumbW + 10 : 0)
      const byline = paper && paper.byline ? wrapLines(paper.byline, '12.5px ' + state.font, Math.min(w + 14 - thumbW, 680), 1) : []
      const bylineH = byline.length ? 17 : 0
      const bottom = y - 12 - 8
      let ty = bottom - big - bylineH - (gistLines.length ? gistLines.length * 17 + 4 : 0)
      ctx.font = titleFont
      const titleLine = wrapLines(title, titleFont, w, 1)
      ctx.fillStyle = paper ? c.text : color
      drawLines(titleLine, lx, ty, big + 4)
      if (thumbW) drawPaperThumb(thumb, lx0, ty - 2, thumbW, Math.max(36, big + 4 + bylineH + (gistLines.length ? gistLines.length * 17 + 4 : 0)))
      if (bylineH) {
        ctx.font = '12.5px ' + state.font; ctx.fillStyle = c.sub
        drawLines(byline, lx, ty + big + 4, 17)
        ctx.font = titleFont
      }
      const nameW = ctx.measureText(titleLine[0] || '').width
      // A locked region wears a padlock after its name; a click on it unlocks.
      const lockW = region && region.locked ? 16 : 0
      const tw = nameW + lockW
      let width = tw
      let chev = null
      let lock = null
      if (lockW) {
        drawLock(lx + nameW + 6, ty + (big + 4) / 2, c.faint)
        lock = { x: lx + nameW + 2, y: ty - 3, w: 16, h: big + 10 }
      }
      if (region) {
        // ▾ open, ▸ folded up (tinted, so a folded region reads as one).
        const cx = left + 6, cy = ty + (big + 4) / 2
        ctx.fillStyle = region.collapsed ? color : c.faint
        ctx.beginPath()
        if (region.collapsed) { ctx.moveTo(cx - 2.5, cy - 4.5); ctx.lineTo(cx + 3.5, cy); ctx.lineTo(cx - 2.5, cy + 4.5) }
        else { ctx.moveTo(cx - 4.5, cy - 2.5); ctx.lineTo(cx + 4.5, cy - 2.5); ctx.lineTo(cx, cy + 3.5) }
        ctx.closePath(); ctx.fill()
        chev = { x: left - 4, y: ty - 4, w: CHEV + 8, h: big + 12 }
        width += CHEV
      }
      if (thumbW) width += thumbW + 10
      const memText = mem && mem.cards ? memoryText(mem) : null
      if (memText) {
        ctx.font = '12px ' + state.font
        const mw = ctx.measureText(memText).width
        if (tw + 10 + 11 + mw <= w + 14) {
          drawPip(lx + tw + 14, ty + 9.5, memoryTone(mem))
          ctx.fillStyle = c.faint
          ctx.fillText(memText, lx + tw + 21, ty + 2)
          width = tw + 21 + mw + (region ? CHEV : 0)
        }
      } else if (count && w - tw > 80) {
        ctx.font = '12px ' + state.font; ctx.fillStyle = c.faint
        const countText = typeof count === 'string' ? count : count + (count === 1 ? ' card' : ' cards')
        ctx.fillText(countText, lx + tw + 10, ty + 2)
        width = tw + 10 + ctx.measureText(countText).width + (region ? CHEV : 0)
      }
      if (gistLines.length) {
        ctx.font = gistFont; ctx.fillStyle = c.sub
        drawLines(gistLines, lx, ty + big + 6 + bylineH, 17)
        for (const l of gistLines) width = Math.max(width, ctx.measureText(l).width + (region ? CHEV : 0))
      }
      return { x: left - 4, y: ty - 4, w: width + 8, h: bottom - ty + 8, chev, lock, nameRect: { x: lx, y: ty - 1, w: nameW, h: big + 6 } }
    }

    // A source's picture, filling the box (cropped to it), or false when
    // there is none yet.
    function drawThumb(node, x, y, w, h, r) {
      const img = state.thumbs.get(node.ref)
      if (!img || !img.complete || !img.naturalWidth) return false
      const k = Math.max(w / img.naturalWidth, h / img.naturalHeight)
      const iw = img.naturalWidth * k, ih = img.naturalHeight * k
      ctx.save(); roundRect(x, y, w, h, r); ctx.clip()
      ctx.drawImage(img, x + (w - iw) / 2, y + (h - ih) / 2, iw, ih)
      ctx.restore()
      return true
    }

    // A clip: the picture cut out of the page, whole (never cropped further),
    // on white like the page it came from, with its name and the learner's
    // note in the foot. Small, it is only its picture.
    function drawClip(node, L, W, H, allowShadow, ghost) {
      const c = state.colors
      const s = state.scale
      const p = ghost ? [ghost.x, ghost.y] : pos(node)
      if (!p) return
      const x = p[0] * s + state.ox, y = p[1] * s + state.oy
      if (x > W || y > H || x + MAX_CARD_W * s < 0) return
      const [cw, ch] = sizeOf(node)
      const w = cw * s, h = ch * s
      if (x + w < 0 || y + h < 0) return
      const base = ctx.globalAlpha
      const tc = ghost ? null : cardColor(node)
      const isPicture = node.kind === 'picture'
      // The room for the learner's words sits at the card's foot; the clip is the rest.
      const annPx = ghost ? 0 : annotationH(node) * s
      const hb = h - annPx
      let alpha = ghost ? 1 : presence(node)
      if (!ghost && state.lens && !(state.lens.positions[node.ref])) alpha = state.lens.hideOthers ? 0.05 : 0.2
      if (!ghost && state.highlight.size && !state.highlight.has(node.ref)) alpha *= 0.3
      ctx.globalAlpha = alpha * base
      const radius = Math.max(2, 10 * s)
      const ringed = !ghost && (state.selection.has(node.ref) || state.highlight.has(node.ref))
      const img = state.thumbs.get(node.ref)
      const ready = !!(img && img.complete && img.naturalWidth)
      if (L === 0) {
        ctx.fillStyle = c.card
        roundRect(x, y, Math.max(2, w), Math.max(2, h), radius); ctx.fill()
        if (ringed) { ctx.strokeStyle = c.select; ctx.lineWidth = 1.5; ctx.stroke() }
        ctx.globalAlpha = base
        return
      }
      const lift = state.lifting || !!(ghost && ghost.lifted)
      const shadow = lift || allowShadow
      if (shadow) {
        ctx.save()
        ctx.shadowColor = c.shadow
        ctx.shadowBlur = lift ? 30 : Math.min(18, 14 * Math.max(0.5, s))
        ctx.shadowOffsetY = lift ? 12 : Math.min(4, 3 * Math.max(0.5, s))
      }
      // A page is white in either theme, as the Reader's PDF is; a picture
      // sits on the card's own background.
      ctx.fillStyle = isPicture ? c.card : '#ffffff'
      roundRect(x, y, w, h, radius); ctx.fill()
      if (shadow) ctx.restore()
      if (tc) { ctx.strokeStyle = withAlpha(tc, 0.7); ctx.lineWidth = 1.6 } else { ctx.strokeStyle = c.hairline; ctx.lineWidth = 1 }
      ctx.stroke()
      if (ringed) {
        ctx.strokeStyle = c.select; ctx.lineWidth = 2
        roundRect(x - 3, y - 3, w + 6, h + 6, radius + 3); ctx.stroke()
      } else if (!ghost && state.hover === node.ref && !state.drag) {
        ctx.strokeStyle = withAlpha(c.select, 0.45); ctx.lineWidth = 1.5
        roundRect(x - 2, y - 2, w + 4, h + 4, radius + 2); ctx.stroke()
      }
      if (!ghost && L >= 2 && isFoldedCard(node)) {
        drawFoldedLine(node, x, y, w, h, radius, tc || TYPE_TINTS[node.type] || TYPE_TINTS.clip, '#1d1d1f')
        ctx.globalAlpha = base
        return
      }
      // The foot shows from the middle zoom in; below that the clip is its
      // picture. A picture has no foot at all: it is its picture, its name a
      // line under it when the card is close.
      const foot = L >= 2 && !isPicture ? (CLIP_FOOT + (node.caption ? CAPTION_ROOM : 0)) * s : 0
      const pad = Math.max(3, 8 * s)
      const bx = x + pad, by = y + pad, bw = w - pad * 2, bh = hb - foot - pad * (foot ? 1 : 2)
      if (node.quote) {
        // A passage: the words the learner marked in the paper, on the
        // highlighter's yellow; a click opens the paper at them.
        if (bw > 2 && bh > 2) {
          ctx.fillStyle = withAlpha('#F5C542', 0.30)
          roundRect(bx, by, bw, bh, Math.max(2, 6 * s)); ctx.fill()
          const qf = Math.max(6, Math.min(13, 12 * s))
          if (qf >= 7) {
            ctx.save()
            roundRect(bx, by, bw, bh, Math.max(2, 6 * s)); ctx.clip()
            ctx.font = qf + 'px ' + state.font
            ctx.fillStyle = '#1d1d1f'
            const inner = Math.max(6, 8 * s)
            const rows = Math.max(1, Math.floor((bh - inner) / (qf + 3)))
            drawLines(wrapLines(node.quote, ctx.font, bw - inner * 2, rows), bx + inner, by + inner * 0.8, qf + 3)
            ctx.restore()
          }
        }
      } else if (ready && bw > 2 && bh > 2) {
        const k = Math.min(bw / img.naturalWidth, bh / img.naturalHeight)
        const iw = img.naturalWidth * k, ih = img.naturalHeight * k
        ctx.save(); roundRect(x, y, w, hb - foot, radius); ctx.clip()
        ctx.drawImage(img, bx + (bw - iw) / 2, by + (bh - ih) / 2, iw, ih)
        ctx.restore()
      } else if (bw > 2 && bh > 2) {
        ctx.fillStyle = withAlpha(TYPE_TINTS[node.type] || TYPE_TINTS.clip, 0.08)
        roundRect(bx, by, bw, bh, Math.max(2, 6 * s)); ctx.fill()
      }
      if (isPicture && L >= 3 && !ghost && node.title) {
        const nf = Math.max(10, Math.min(12, 11.5 * s))
        ctx.font = nf + 'px ' + state.font; ctx.fillStyle = c.faint
        ctx.fillText(wrapLines(node.title, ctx.font, w, 1)[0] || '', x + 2, y + h + 5)
      }
      if (foot) {
        ctx.save()
        roundRect(x, y, w, h, radius); ctx.clip()
        if (tc) { ctx.fillStyle = withAlpha(tc, 0.12); ctx.fillRect(x, y + hb - foot, w, foot) }
        ctx.strokeStyle = 'rgba(0,0,0,0.07)'; ctx.lineWidth = 1
        ctx.beginPath(); ctx.moveTo(x, y + hb - foot); ctx.lineTo(x + w, y + hb - foot); ctx.stroke()
        const tx = x + Math.max(6, 12 * s), tw = w - Math.max(12, 24 * s)
        const tf = Math.max(9, Math.min(13, 12.5 * s))
        let ty = y + hb - foot + Math.max(3, 7 * s)
        ctx.fillStyle = TYPE_TINTS[node.type] || TYPE_TINTS.clip
        ctx.beginPath(); ctx.arc(tx + 3, ty + tf * 0.55, Math.max(1.5, 3 * s), 0, Math.PI * 2); ctx.fill()
        ctx.fillStyle = '#1d1d1f'; ctx.font = '600 ' + tf + 'px ' + state.font
        drawLines(wrapLines(node.title, ctx.font, tw - 11, 1), tx + 11, ty, tf + 3)
        ty += tf + Math.max(2, 4 * s)
        const note = (node.detail && node.detail[0]) || ''
        const nf = Math.max(8.5, Math.min(12, 11.5 * s))
        if (node.caption) {
          // A figure: its caption under its name, as many lines as the foot
          // holds, after the learner's note when there is one.
          let room = Math.max(1, Math.floor((y + hb - ty - Math.max(3, 6 * s)) / (nf + 3)))
          if (note) {
            ctx.font = 'italic ' + nf + 'px ' + state.font; ctx.fillStyle = '#3a3a3c'
            drawLines(wrapLines(note, ctx.font, tw, 1), tx, ty, nf + 3)
            ty += nf + 3; room -= 1
          }
          if (room > 0) {
            ctx.font = nf + 'px ' + state.font; ctx.fillStyle = '#6e6e73'
            drawLines(wrapLines(node.caption, ctx.font, tw, room), tx, ty, nf + 3)
          }
        } else {
          ctx.font = (note ? 'italic ' : '') + nf + 'px ' + state.font
          ctx.fillStyle = note ? '#3a3a3c' : '#8e8e93'
          drawLines(wrapLines(note || node.sub, ctx.font, tw, 1), tx, ty, nf + 3)
        }
        ctx.restore()
      }
      if (annPx > 0 && L >= 2) drawAnnotation(node, x, y + hb, w, annPx, isPicture ? c.text : '#1d1d1f')
      ctx.globalAlpha = base
    }

    // ---- What Sapience showed: the small marks
    //
    // A question's badge (an orange ? while open, a green ✓ once answered; a
    // press on it toggles that, `questionHits`) and a source's read mark.
    function drawQuestionBadge(cx, cy, answered, ref) {
      const c = state.colors
      ctx.save()
      ctx.fillStyle = answered ? c.memSolid : QUESTION_TINT
      ctx.beginPath(); ctx.arc(cx, cy, BADGE_R, 0, Math.PI * 2); ctx.fill()
      ctx.strokeStyle = '#ffffff'; ctx.fillStyle = '#ffffff'
      if (answered) {
        ctx.lineWidth = 1.8; ctx.lineCap = 'round'; ctx.lineJoin = 'round'
        ctx.beginPath(); ctx.moveTo(cx - 3.6, cy + 0.3); ctx.lineTo(cx - 1.1, cy + 2.9); ctx.lineTo(cx + 3.8, cy - 2.7); ctx.stroke()
      } else {
        ctx.font = '700 11px ' + state.font; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'
        ctx.fillText('?', cx, cy + 0.5)
      }
      ctx.restore()
      if (ref && !state.exporting) state.questionHits.push({ ref, x: cx - BADGE_R - 2, y: cy - BADGE_R - 2, w: BADGE_R * 2 + 4, h: BADGE_R * 2 + 4 })
    }
    function drawReadMark(cx, cy) {
      ctx.save()
      ctx.fillStyle = state.colors.memSolid
      ctx.beginPath(); ctx.arc(cx, cy, 6.5, 0, Math.PI * 2); ctx.fill()
      ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 1.7; ctx.lineCap = 'round'; ctx.lineJoin = 'round'
      ctx.beginPath(); ctx.moveTo(cx - 3, cy + 0.3); ctx.lineTo(cx - 0.8, cy + 2.4); ctx.lineTo(cx + 3.2, cy - 2.2); ctx.stroke()
      ctx.restore()
    }

    // ---- Words about a card on this canvas
    //
    // In the bottom room of a card (`annotationH`), under a hairline: 12.5 px,
    // the ink at 85%, the first sentence in bold when more follows it (the
    // bold lead). From the middle zoom in only; the room is kept at every zoom.
    // The page wraps the words by measuring them but draws at most as many
    // lines as the room was reckoned for, the last ending in … when words are left.
    function leadLength(text) {
      const m = /^[\s\S]*?[.!?。！？…]["'”’)\]]*(?=\s)/.exec(text)
      return m && text.slice(m[0].length).trim() ? m[0].length : 0
    }
    // The words as lines of {t, b, x}: a word, whether it is in the bold lead, and its offset on the line.
    function annotationRuns(text, width, maxLines, fs) {
      const key = 'ann|' + fs + '|' + width + '|' + maxLines + '|' + text
      const hit = wrapCache.get(key)
      if (hit) return hit
      const lead = leadLength(text)
      const measure = (t, b) => { ctx.font = (b ? '600 ' : '') + fs + 'px ' + state.font; return ctx.measureText(t).width }
      const lines = []
      let line = [], used = 0
      for (const m of text.matchAll(/\S+|\n/g)) {
        if (m[0] === '\n') { lines.push(line); line = []; used = 0; continue }
        const b = m.index < lead
        const w = measure(m[0], b), gap = line.length ? measure(' ', b) : 0
        if (line.length && used + gap + w > width) { lines.push(line); line = []; used = 0 }
        const x = used + (line.length ? gap : 0)
        line.push({ t: m[0], b, x })
        used = x + w
      }
      if (line.length) lines.push(line)
      if (lines.length > maxLines) {
        lines.length = Math.max(1, maxLines)
        const last = lines[lines.length - 1]
        const ellipsis = measure('…', false)
        while (last.length > 1 && last[last.length - 1].x + measure(last[last.length - 1].t, last[last.length - 1].b) + ellipsis > width) last.pop()
        const tail = last[last.length - 1]
        if (tail) {
          let t = tail.t
          while (t.length > 1 && tail.x + measure(t + '…', tail.b) > width) t = t.slice(0, -1)
          tail.t = t + '…'
        } else last.push({ t: '…', b: false, x: 0 })
      }
      if (wrapCache.size > 6000) wrapCache.clear()
      wrapCache.set(key, lines)
      return lines
    }
    // How many lines the words are drawn in at the card's own width: for the harness and the tests.
    function annotationLinesOf(node) {
      const text = annotationOf(node)
      if (!text) return 0
      const w = cardW(node)
      return annotationRuns(text, w - ANN_SIDE, annotationLineCount(text, w), 12.5).length
    }
    // The room starts at (x, y) on screen, `hPx` tall, as wide as the card.
    function drawAnnotation(node, x, y, w, hPx, ink) {
      const text = annotationOf(node)
      const ed = state.editor
      if (!text || hPx < 14 || (ed && ed.kind === 'annotation' && ed.ref === node.ref)) return
      const s = state.scale
      const padX = Math.max(6, 14 * s)
      const fs = clamp(12.5 * s, 8.5, 12.5), lh = fs * 1.28
      const topPad = Math.max(3, 5 * s)
      const room = Math.max(1, Math.min(annotationLineCount(text, cardW(node)), Math.floor((hPx - topPad * 1.5) / lh)))
      const lines = annotationRuns(text, w - padX * 2, room, fs)
      ctx.save()
      ctx.beginPath(); ctx.rect(x, y, w, hPx); ctx.clip()
      ctx.strokeStyle = withAlpha(ink, 0.12); ctx.lineWidth = 1
      ctx.beginPath(); ctx.moveTo(x + padX, Math.round(y) + 0.5); ctx.lineTo(x + w - padX, Math.round(y) + 0.5); ctx.stroke()
      ctx.fillStyle = withAlpha(ink, 0.85)
      lines.forEach((ln, i) => {
        for (const word of ln) {
          ctx.font = (word.b ? '600 ' : '') + fs + 'px ' + state.font
          ctx.fillText(word.t, x + padX + word.x, y + topPad + i * lh)
        }
      })
      ctx.restore()
    }

    // ---- A mind map's nodes
    //
    // In a region laid out as a mind map an Idea is small, as Sapience's:
    // the root a card with a 1.5-point outline in the region's tint and its
    // title centred (16 px, 600); a branch its words alone (13 px); a leaf its
    // words in a pill outlined 1.2 points in its branch colour (12.5 px). The
    // words wrap inside `treeNodeSize`'s box (the text scales with the card, so
    // the lines are the ones the box was reckoned for). A ≡ after the words
    // says there is a note. `spec` is {role, tint, allowShadow} for a placed node,
    // and for a proposed one also {w, h, ghost: {x, y, lifted}}.
    function drawTreeNode(node, L, W, H, spec) {
      const c = state.colors
      const s = state.scale
      const ghost = spec.ghost
      const p = ghost ? [ghost.x, ghost.y] : pos(node)
      if (!p) return
      const [cw, ch] = ghost ? [spec.w, spec.h] : sizeOf(node)
      const x = p[0] * s + state.ox, y = p[1] * s + state.oy
      const w = cw * s, h = ch * s
      if (x > W || y > H || x + w < 0 || y + h < 0) return
      const role = spec.role, root = role === 'root', leaf = role === 'leaf'
      const tint = spec.tint
      let alpha = ghost ? 1 : presence(node)
      if (!ghost && state.highlight.size && !state.highlight.has(node.ref)) alpha *= 0.3
      const mark = ghost ? null : markOf(node.ref)
      if (mark && mark.dusty) alpha *= DUSTY_ALPHA
      const ringed = !ghost && (state.selection.has(node.ref) || state.highlight.has(node.ref))
      const base = ctx.globalAlpha
      ctx.globalAlpha = alpha * base
      const radius = leaf ? h / 2 : root ? Math.max(3, 12 * s) : Math.max(2, 6 * s)
      const lift = state.lifting || !!(ghost && ghost.lifted)
      if (L === 0) {
        ctx.fillStyle = root ? c.card : withAlpha(tint, leaf ? 0.55 : 0.8)
        roundRect(x, y, Math.max(2, w), Math.max(2, h), Math.min(radius, Math.max(2, h) / 2)); ctx.fill()
        if (root) { ctx.strokeStyle = tint; ctx.lineWidth = 1; ctx.stroke() }
        if (ringed) { ctx.strokeStyle = c.select; ctx.lineWidth = 1.5; ctx.stroke() }
        ctx.globalAlpha = base
        return
      }
      if (root || leaf) {
        const shadow = lift || (root && spec.allowShadow)
        if (shadow) {
          ctx.save()
          ctx.shadowColor = c.shadow
          ctx.shadowBlur = lift ? 24 : Math.min(14, 12 * Math.max(0.5, s))
          ctx.shadowOffsetY = lift ? 10 : Math.min(3, 2.5 * Math.max(0.5, s))
        }
        ctx.fillStyle = c.card
        roundRect(x, y, w, h, radius); ctx.fill()
        if (shadow) ctx.restore()
        ctx.strokeStyle = tint; ctx.lineWidth = root ? 1.5 : 1.2
        if (ghost) ctx.setLineDash([5, 4])
        ctx.stroke(); ctx.setLineDash([])
      } else if (ghost) {
        // A proposed branch has no outline of its own: ForeverLM's, dashed.
        ctx.strokeStyle = c.ai; ctx.lineWidth = 1; ctx.setLineDash([4, 3])
        roundRect(x, y, w, h, radius); ctx.stroke(); ctx.setLineDash([])
      }
      if (ringed) {
        ctx.strokeStyle = c.select; ctx.lineWidth = 2
        roundRect(x - 3, y - 3, w + 6, h + 6, radius + 3); ctx.stroke()
      } else if (!ghost && state.hover === node.ref && !state.drag) {
        ctx.strokeStyle = withAlpha(c.select, 0.45); ctx.lineWidth = 1.5
        roundRect(x - 2, y - 2, w + 4, h + 4, radius + 2); ctx.stroke()
      }
      // The words, scaled with the card between 0.55 and 3 times their size.
      const k = clamp(s, 0.55, 3)
      const lineH = (root ? 21 : 17)
      const px = (root ? 18 : 12) * s
      const tw = w - 2 * px
      const note = ideaNote(node)
      if (tw >= 14) {
        const maxLines = Math.max(1, Math.round((ch - 2 * (root ? 12 : 7)) / lineH))
        // The box was reckoned from the characters, so words a little wider than it
        // allowed (a bold face, wide letters) are set a little smaller before they are cut.
        let font = '', lines = []
        for (const shrink of [1, 0.93, 0.86]) {
          font = (root ? '600 ' : '500 ') + (root ? 16 : leaf ? 12.5 : 13) * k * shrink + 'px ' + state.font
          lines = wrapLines(node.title, font, tw, maxLines)
          if (!(lines.length && lines[lines.length - 1].endsWith('…') && !String(node.title).trim().endsWith('…'))) break
        }
        const lh = lineH * k
        ctx.save()
        roundRect(x, y, w, h, radius); ctx.clip()
        ctx.font = font; ctx.fillStyle = c.text
        ctx.textBaseline = 'middle'; ctx.textAlign = role === 'branch' ? 'left' : 'center'
        // The ≡ of a node with a note sits after its last line; a centred block of words makes room for it.
        const noteRoom = note && L >= 2 && lines.length ? 4 + ctx.measureText('≡').width : 0
        const tx = role === 'branch' ? x + px : x + w / 2 - noteRoom / 2
        const top = y + (h - lines.length * lh) / 2 + lh / 2
        lines.forEach((ln, i) => ctx.fillText(ln, tx, top + i * lh))
        if (noteRoom) {
          const lw = ctx.measureText(lines[lines.length - 1]).width
          ctx.fillStyle = c.faint; ctx.textAlign = 'left'
          ctx.fillText('≡', (role === 'branch' ? tx + lw : tx + lw / 2) + 4, top + (lines.length - 1) * lh)
        }
        ctx.restore()
      }
      // A question's badge sits on the node's left edge, where its branch arrives.
      if (L >= 2 && isQuestionTitle(node.title)) {
        const placed = !ghost && placementOf(node)
        drawQuestionBadge(x, y + h / 2, !!(placed && placed.answered), ghost ? null : node.ref)
      }
      ctx.globalAlpha = base
    }

    // ---- A paper as a page
    //
    // A source whose card shows page n of its PDF: white in both themes, the
    // picture contained at the top, then the foot: the kind's dot and the title
    // in two lines (13 px, 600), the byline in one (12 px). Far out it is its
    // picture. A green ✓ on the picture's top right for a paper the learner has
    // read; while the card is the one selected, or hovered, a pill floats at
    // the bottom of the picture, `‹  n / N  ›`, whose arrows turn the page.
    function pageFaceImage(node, n) {
      const ready = (img) => img && img.complete && img.naturalWidth ? img : null
      const own = ready(state.thumbs.get('page:' + String(node.ref).replace(/^source:/, '') + ':' + n))
      // Until the page's picture comes the first page is the source's own thumbnail.
      return own || (n === 1 ? ready(state.thumbs.get(node.ref)) : null)
    }
    function drawPageFace(node, L, W, H, allowShadow) {
      const c = state.colors
      const s = state.scale
      const p = pos(node)
      if (!p) return
      const x = p[0] * s + state.ox, y = p[1] * s + state.oy
      if (x > W || y > H || x + MAX_CARD_W * s < 0) return
      const [cw, ch] = sizeOf(node)
      const w = cw * s, h = ch * s
      if (x + w < 0 || y + h < 0) return
      const base = ctx.globalAlpha
      const tc = cardColor(node)
      let alpha = presence(node)
      if (state.highlight.size && !state.highlight.has(node.ref)) alpha *= 0.3
      const mark = markOf(node.ref)
      const dusty = !!(mark && mark.dusty)
      if (dusty) alpha *= DUSTY_ALPHA
      ctx.globalAlpha = alpha * base
      const radius = Math.max(2, 10 * s)
      const ringed = state.selection.has(node.ref) || state.highlight.has(node.ref)
      if (L === 0) {
        ctx.fillStyle = '#ffffff'
        roundRect(x, y, Math.max(2, w), Math.max(2, h), radius); ctx.fill()
        if (ringed) { ctx.strokeStyle = c.select; ctx.lineWidth = 1.5; ctx.stroke() }
        ctx.globalAlpha = base
        return
      }
      const lift = state.lifting
      const shadow = lift || allowShadow
      if (shadow) {
        ctx.save()
        ctx.shadowColor = c.shadow
        ctx.shadowBlur = lift ? 30 : Math.min(18, 14 * Math.max(0.5, s))
        ctx.shadowOffsetY = lift ? 12 : Math.min(4, 3 * Math.max(0.5, s))
      }
      ctx.fillStyle = '#ffffff'
      roundRect(x, y, w, h, radius); ctx.fill()
      if (shadow) ctx.restore()
      if (tc) { ctx.strokeStyle = withAlpha(tc, 0.7); ctx.lineWidth = 1.6 } else { ctx.strokeStyle = c.hairline; ctx.lineWidth = 1 }
      ctx.stroke()
      if (ringed) {
        ctx.strokeStyle = c.select; ctx.lineWidth = 2
        roundRect(x - 3, y - 3, w + 6, h + 6, radius + 3); ctx.stroke()
      } else if (state.hover === node.ref && !state.drag) {
        ctx.strokeStyle = withAlpha(c.select, 0.45); ctx.lineWidth = 1.5
        roundRect(x - 2, y - 2, w + 4, h + 4, radius + 2); ctx.stroke()
      }
      // From the top: the page, the foot, the room for the learner's words.
      const annPx = annotationH(node) * s
      const pageH = Math.max(1, ch - PAGE_FOOT - annotationH(node)) * s
      const n = pageOf(node)
      ctx.save()
      roundRect(x, y, w, h, radius); ctx.clip()
      const img = pageFaceImage(node, n)
      const ratio = img ? img.naturalWidth / img.naturalHeight : node.aspect > 0 ? node.aspect : LETTER_ASPECT
      const dw = Math.min(w, pageH * ratio), dh = dw / ratio
      const ix = x + (w - dw) / 2
      if (img) ctx.drawImage(img, ix, y, dw, dh)
      else {
        // The picture has not come: a blank sheet with its number.
        ctx.fillStyle = '#f1f1ef'; ctx.fillRect(ix, y, dw, dh)
        const nf = clamp(dh * 0.16, 9, 44)
        ctx.font = '600 ' + nf + 'px ' + state.font; ctx.fillStyle = '#c3c3bf'
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle'
        ctx.fillText(String(n), ix + dw / 2, y + dh / 2)
        ctx.textAlign = 'left'; ctx.textBaseline = 'top'
      }
      if (L >= 2) {
        if (tc) { ctx.fillStyle = withAlpha(tc, 0.12); ctx.fillRect(x, y + pageH, w, h - pageH - annPx) }
        const tx = x + Math.max(8, 12 * s), tw = w - Math.max(16, 24 * s)
        let ty = y + pageH + Math.max(4, 8 * s)
        const tf = clamp(13 * s, 9, 13), lh = tf + 3
        ctx.fillStyle = TYPE_TINTS[node.type] || TYPE_TINTS.paper
        ctx.beginPath(); ctx.arc(tx + 3.5, ty + tf * 0.55, Math.max(2, 3.2 * Math.min(1, s + 0.4)), 0, Math.PI * 2); ctx.fill()
        ctx.fillStyle = '#1d1d1f'; ctx.font = '600 ' + tf + 'px ' + state.font
        const titleLines = wrapLines(node.title, ctx.font, tw - 12, 2)
        drawLines(titleLines, tx + 12, ty, lh)
        ty += titleLines.length * lh + 2
        const bf = clamp(12 * s, 8.5, 12)
        if (node.sub && y + h - annPx - ty >= bf + 2) {
          ctx.font = bf + 'px ' + state.font; ctx.fillStyle = '#6e6e73'
          drawLines(wrapLines(node.sub, ctx.font, tw, 1), tx, ty, bf + 3)
        }
      }
      ctx.restore()
      if (annPx > 0 && L >= 2) drawAnnotation(node, x, y + h - annPx, w, annPx, '#1d1d1f')
      if (L >= 2 && node.read) drawReadMark(x + w - 14, y + 14)
      const selected = state.selection.size === 1 && state.selection.has(node.ref)
      if (L >= 2 && node.pages > 1 && pageH >= 60 && (selected || state.hover === node.ref) && !state.exporting && !state.lifting) drawStepper(node, n, x + w / 2, y + pageH - 22)
      if (dusty) drawHatch(x, y, w, h, radius)
      ctx.globalAlpha = base
    }
    // `‹  n / N  ›` with its middle at (cx, cy) on screen; the arrows are the turn
    // buttons (`pageHits`), the numbers swallow a press so it never starts a drag.
    function drawStepper(node, n, cx, cy) {
      const text = n + ' / ' + node.pages
      ctx.font = '600 12px ' + state.font
      const tw = ctx.measureText(text).width, arrow = 26, ph = 24
      const pw = tw + arrow * 2
      const x = cx - pw / 2, y = cy - ph / 2
      ctx.save()
      ctx.shadowColor = 'rgba(0,0,0,0.28)'; ctx.shadowBlur = 8; ctx.shadowOffsetY = 2
      ctx.fillStyle = 'rgba(30,30,32,0.86)'
      roundRect(x, y, pw, ph, ph / 2); ctx.fill()
      ctx.restore()
      ctx.save()
      const a = ctx.globalAlpha
      ctx.fillStyle = '#ffffff'; ctx.textBaseline = 'middle'; ctx.textAlign = 'center'
      ctx.fillText(text, cx, cy + 0.5)
      ctx.font = '600 17px ' + state.font
      // An arrow at the end of the PDF is dimmed.
      ctx.globalAlpha = a * (n > 1 ? 1 : 0.32)
      ctx.fillText('‹', x + arrow / 2, cy - 0.5)
      ctx.globalAlpha = a * (n < node.pages ? 1 : 0.32)
      ctx.fillText('›', x + pw - arrow / 2, cy - 0.5)
      ctx.restore()
      state.pageHits.push({ ref: node.ref, dir: -1, x, y, w: arrow, h: ph }, { ref: node.ref, dir: 0, x: x + arrow, y, w: pw - arrow * 2, h: ph }, { ref: node.ref, dir: 1, x: x + pw - arrow, y, w: arrow, h: ph })
    }
    function hitPageStepper(px, py) {
      return state.pageHits.find(b => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h) || null
    }
    // Turns a page face's page by one: drawn at once, then told to the host.
    function turnPage(ref, delta) {
      const node = state.byRef.get(ref)
      if (!node || !isPageFace(node)) return false
      const p = state.placements[ref]
      const next = clamp(pageOf(node) + delta, 1, node.pages)
      if (next === pageOf(node)) return false
      p.page = next
      host.post('placementChanged', { items: [{ ref, page: next }] })
      invalidate()
      return true
    }
    // The one selected card, when it is a page face with more than a page.
    function onePageFace() {
      if (state.selection.size !== 1) return null
      const node = state.byRef.get([...state.selection][0])
      return node && isPageFace(node) && node.pages > 1 ? node : null
    }
    // A question marked answered here, or open again (the badge's press).
    function toggleAnswered(ref) {
      const p = state.placements[ref]
      if (!p || !state.byRef.has(ref)) return
      const next = !p.answered
      if (next) p.answered = true; else delete p.answered
      host.post('placementChanged', { items: [{ ref, answered: next ? true : null }] })
      invalidate()
    }

    // A card's face for the zoom. `ghost` draws it as one of ForeverLM's
    // proposals instead: at the ghost's spot ({x, y, lifted}), as a placed
    // card, never selected, hovered or marked.
    function drawNode(node, L, W, H, allowShadow, ghost) {
      if (node.kind === 'clip' || node.kind === 'page' || node.kind === 'picture') return drawClip(node, L, W, H, allowShadow, ghost)
      // A mind map's node (or a proposed one) and a paper shown as a page have their own faces.
      if (ghost && ghost.tree) return drawTreeNode(node, L, W, H, { role: ghost.tree.role, tint: ghost.tree.tint, w: ghost.tree.w, h: ghost.tree.h, ghost })
      const mind = ghost ? null : mindInfo(node)
      if (mind) return drawTreeNode(node, L, W, H, { role: mind.role, tint: nodeTint(node, mind), allowShadow })
      // (A page face folded to its title line is the usual folded card.)
      if (!ghost && isPageFace(node) && !isFoldedCard(node)) return drawPageFace(node, L, W, H, allowShadow)
      const c = state.colors
      const s = state.scale
      const p = ghost ? [ghost.x, ghost.y] : pos(node)
      if (!p) return
      const [wx, wy] = p
      const x = wx * s + state.ox, y = wy * s + state.oy
      // Off the view's right or bottom, or left of it by more than the widest card,
      // is out before the card is measured.
      if (x > W || y > H || x + MAX_CARD_W * s < 0) return
      const [cw, ch] = sizeOf(node)
      const w = cw * s
      // `hFull` is the whole card; `h` becomes the card without the room for its annotation.
      const hFull = ch * s
      let h = hFull
      if (x + w < 0 || y + h < 0) return
      const lensed = !ghost && !!(state.lens && state.lens.positions[node.ref])
      const lifted = !!ghost || isPlaced(node) || lensed
      let alpha = ghost ? 1 : presence(node)
      if (!ghost && state.lens && !lensed) alpha = state.lens.hideOthers ? 0.05 : 0.2
      if (!ghost && state.highlight.size && !state.highlight.has(node.ref)) alpha *= 0.3
      const isIdea = node.kind === 'idea'
      // An Idea shown as plain words: no sticky, shadow or hairline.
      const plain = isIdea && !ghost && isPlain(node)
      // The colour the learner gave the card tints its face: a source or Doc
      // the tint over white with a hairline in it, an Idea the tint in place
      // of the sticky yellow, its words in whichever ink reads on it.
      const tc = ghost ? null : cardColor(node)
      const pal = isIdea && tc ? ideaPalette(tc) : null
      const ink = plain ? c.text : pal ? pal.ink : c.stickyText
      const mark = ghost ? null : markOf(node.ref)
      const dusty = !!(mark && mark.dusty)
      if (dusty) alpha *= DUSTY_ALPHA
      const face = isIdea ? null : faceOf(node)
      const ringed = !ghost && (state.selection.has(node.ref) || state.highlight.has(node.ref))
      const radius = Math.max(2, (isIdea ? 4 : 12) * s)
      const base = ctx.globalAlpha
      ctx.globalAlpha = alpha * base

      if (L === 0) {
        ctx.fillStyle = plain ? withAlpha(c.text, 0.16) : isIdea ? (pal ? pal.fill : c.sticky) : lifted ? c.card : c.flat
        roundRect(x, y, Math.max(2, w), Math.max(2, h), radius); ctx.fill()
        if (tc && !isIdea) { ctx.fillStyle = withAlpha(tc, state.dark ? 0.22 : 0.14); ctx.fill() }
        if (ringed) { ctx.strokeStyle = c.select; ctx.lineWidth = 1.5; ctx.stroke() }
        if (dusty) drawHatch(x, y, Math.max(2, w), Math.max(2, h), radius)
        ctx.globalAlpha = base
        return
      }

      // The card.
      const lift = state.lifting || !!(ghost && ghost.lifted)
      const shadow = !plain && (lift || (lifted && allowShadow))
      if (shadow) {
        ctx.save()
        ctx.shadowColor = c.shadow
        ctx.shadowBlur = lift ? 30 : Math.min(18, 14 * Math.max(0.5, s))
        ctx.shadowOffsetY = lift ? 12 : Math.min(4, 3 * Math.max(0.5, s))
      }
      if (!plain) {
        ctx.fillStyle = isIdea ? (pal ? pal.fill : c.sticky) : lifted || lift ? c.card : c.flat
        roundRect(x, y, w, h, radius); ctx.fill()
      }
      if (shadow) ctx.restore()
      if (tc && !isIdea) {
        ctx.fillStyle = withAlpha(tc, state.dark ? 0.2 : 0.12); ctx.fill()
        ctx.strokeStyle = withAlpha(tc, 0.55); ctx.lineWidth = 1.4; ctx.stroke()
      } else if (!lifted && !isIdea) { ctx.strokeStyle = c.hairline; ctx.lineWidth = 1; ctx.stroke() }

      if (ringed) {
        ctx.strokeStyle = c.select; ctx.lineWidth = 2
        roundRect(x - 3, y - 3, w + 6, h + 6, radius + 3); ctx.stroke()
      } else if (!ghost && state.hover === node.ref && !state.drag) {
        ctx.strokeStyle = withAlpha(c.select, 0.45); ctx.lineWidth = 1.5
        roundRect(x - 2, y - 2, w + 4, h + 4, radius + 2); ctx.stroke()
      }

      // The room for the learner's words (every card but an Idea) takes the foot of the card.
      const annPx = ghost ? 0 : annotationH(node) * s
      h = hFull - annPx
      const pad = Math.max(6, 14 * s)
      const tint = tc || TYPE_TINTS[node.type] || TYPE_TINTS[node.kind] || TYPE_TINTS.other
      const kept = mark && mark.cards > 0 ? mark : null
      // A folded card is its title line, from the middle zoom in.
      if (!ghost && L >= 2 && isFoldedCard(node)) {
        drawFoldedLine(node, x, y, w, h, radius, tint, isIdea ? ink : c.text)
        if (dusty) drawHatch(x, y, w, hFull, radius)
        ctx.globalAlpha = base
        return
      }
      // Small: the card is its picture, or its kind's colour and its title
      // (its far face, when ForeverLM has written one); a title cut to a few
      // letters says nothing, so none is drawn.
      if (L === 1 && !isIdea) {
        if (!drawThumb(node, x, y, w, h, radius)) {
          ctx.fillStyle = withAlpha(tint, state.dark ? 0.22 : 0.12)
          roundRect(x, y, w, h, radius); ctx.fill()
          const far = face && face.far ? face.far : null
          const tf = far ? 11 : 10.5
          const lh = far ? 14 : tf + 3
          const tw1 = w - 12
          const titleFont = (far ? '700 ' : '600 ') + tf + 'px ' + state.font
          const maxLines = Math.min(far ? 2 : 99, Math.floor((h - 10 - (kept ? 8 : 0)) / lh))
          ctx.font = titleFont
          const fits = maxLines >= (far ? 1 : 2) && tw1 >= 58
          if (fits) {
            ctx.save(); roundRect(x, y, w, h, radius); ctx.clip()
            ctx.fillStyle = c.text
            drawLines(wrapLines(far || node.title, titleFont, far ? tw1 - 9 : tw1, maxLines), x + 6, y + 5, lh)
            // ForeverLM wrote it: its mark in the corner.
            if (far) { ctx.fillStyle = c.ai; ctx.font = '600 9px ' + state.font; ctx.fillText('✦', x + w - 12, y + 5) }
            ctx.restore()
          } else {
            ctx.fillStyle = tint; ctx.font = '700 ' + Math.max(9, Math.min(16, h * 0.4)) + 'px ' + state.font
            const letter = (node.title || '?').replace(/^[^A-Za-z0-9]+/, '').charAt(0).toUpperCase()
            const lw = ctx.measureText(letter).width
            ctx.fillText(letter, x + (w - lw) / 2, y + h * 0.28)
          }
        } else {
          ctx.fillStyle = tint
          ctx.beginPath(); ctx.arc(x + w - 7, y + 7, 3.5, 0, Math.PI * 2); ctx.fill()
          ctx.strokeStyle = c.card; ctx.lineWidth = 1.2; ctx.stroke()
        }
        if (kept) drawPip(x + 7, y + h - 7, memoryTone(kept), true)
        if (dusty) drawHatch(x, y, w, hFull, radius)
        ctx.globalAlpha = base
        return
      }
      // Larger: the picture as a tile on the card's left, the words beside it.
      let left = x
      if (!isIdea && state.thumbs.has(node.ref)) {
        const side = h - pad * 1.2
        const tileW = side * (L === 2 ? 0.58 : 0.78)
        if (drawThumb(node, x + pad * 0.6, y + pad * 0.6, tileW, side, Math.max(2, 6 * s))) left = x + pad * 0.6 + tileW - pad * 0.4
      }
      // How the card's kept cards stand sits at its foot, so the words stop
      // above it.
      const chip = kept && L >= 2 ? memoryChip(kept, x, y, h, L, pad) : null
      const chipRow = chip ? y + h - chip.y + 2 : 0
      // A source the learner has read wears a green ✓ on its corner, and its words stop short of it.
      const reads = !isIdea && !ghost && L >= 2 && !!node.read
      const tw = x + w - left - pad * 2 - (L === 2 && !isIdea ? 8 : 0) - (reads ? 14 : 0)
      if (tw < 24 || h < 16) {
        if (chip) drawMemoryChip(chip)
        if (dusty) drawHatch(x, y, w, hFull, radius)
        ctx.globalAlpha = base
        return
      }
      ctx.save()
      roundRect(x, y, w, hFull, radius); ctx.clip()
      let cy = y + pad * 0.85

      const tf = isIdea ? (L === 1 ? 12 : 14) : (L === 1 ? 11.5 : L === 2 ? 13 : 14)
      const weight = isIdea ? '500 ' : '600 '
      const titleFont = weight + tf + 'px ' + state.font
      // Mid-size cards give the title the room; the kind shows as a dot in the corner.
      const showSub = L >= 3 && !isIdea && (node.sub || node.type)
      // A chat and a canvas wear a glyph before their title instead of the kind's dot.
      const glyph = node.kind === 'chat' || node.kind === 'canvas' ? node.kind : null
      // A question's badge, at the top left inside the padding, the title after it.
      const asks = isIdea && L >= 2 && isQuestionTitle(node.title)
      const gi = glyph && L >= 2 ? 17 : asks ? BADGE_R * 2 + 6 : 0
      if (L === 2 && !isIdea && !glyph && !reads) {
        ctx.fillStyle = tint
        ctx.beginPath(); ctx.arc(x + w - 8, y + 8, 3, 0, Math.PI * 2); ctx.fill()
      }
      // An Idea says how much evidence it has at its foot, when it has the
      // room; its title stops above that line.
      const evidence = isIdea && !ghost && h >= 60 ? (state.evidence.get(node.ref) || []).length : 0
      const footRow = Math.max(chipRow, evidence ? 14 + pad * 0.1 : 0, kept && !chip ? 9 : 0)
      if (face) drawFaceText(node, face, L, left + pad, cy, tw, y + h - pad * 0.5 - chipRow, titleFont, tf, showSub, tint)
      else {
        ctx.fillStyle = isIdea ? ink : c.text
        const room = Math.max(1, Math.floor((y + h - cy - pad * 0.5 - footRow - (showSub ? 17 : 0)) / (tf + 4)))
        const titleLines = wrapLines(node.title, titleFont, tw - gi, Math.min(isIdea ? IDEA_TITLE_LINES : 3, room))
        ctx.font = titleFont
        drawLines(titleLines, left + pad + gi, cy, tf + 4)
        if (glyph && gi) drawKindGlyph(glyph, left + pad + 1, cy + 1, 13, tint)
        if (asks) drawQuestionBadge(left + pad + BADGE_R, cy + 9, !ghost && !!(placementOf(node) && placementOf(node).answered), ghost ? null : node.ref)
        cy += titleLines.length * (tf + 4) + 3
        // An Idea's note under its title, as far as the card has room.
        if (isIdea && !ghost && L >= 2) {
          const note = ideaNote(node)
          const nroom = Math.floor((y + h - cy - pad * 0.5 - footRow) / 16)
          if (note && nroom > 0) {
            ctx.font = '12.5px ' + state.font; ctx.fillStyle = plain ? c.sub : withAlpha(ink, 0.78)
            drawLines(wrapLines(note, ctx.font, tw, Math.min(IDEA_NOTE_LINES, nroom)), left + pad, cy + 1, 16)
          }
        }

        // Its kind as a coloured dot, then who and when.
        if (showSub) {
          ctx.fillStyle = tint
          ctx.beginPath(); ctx.arc(left + pad + 3, cy + 7, 3, 0, Math.PI * 2); ctx.fill()
          ctx.fillStyle = c.sub
          ctx.font = '12px ' + state.font
          drawLines(wrapLines(node.sub || TYPE_NAMES[node.type] || 'Source', ctx.font, tw - 11, 1), left + pad + 11, cy, 15)
          cy += 19
        }
        if (L === 3 && node.detail && node.detail.length && !isIdea) {
          ctx.fillStyle = c.faint
          ctx.font = '12px ' + state.font
          const lines = Math.floor((y + h - cy - pad * 0.4 - chipRow) / 16)
          if (lines > 0) drawLines(wrapLines(node.detail.join('  ·  '), ctx.font, tw, lines), left + pad, cy, 16)
        }
      }
      // The evidence line follows how its kept cards stand, when they show.
      if (evidence) {
        ctx.font = '600 11px ' + state.font
        ctx.fillStyle = withAlpha(ink, 0.7)
        ctx.fillText('▤ ' + evidence + (evidence === 1 ? ' source' : ' sources'), chip ? chip.x + chip.w + 8 : x + pad, y + h - pad * 0.6 - 13)
      }
      ctx.restore()
      if (annPx > 0 && L >= 2) drawAnnotation(node, x, y + h, w, annPx, c.text)
      if (reads) drawReadMark(x + w - 13, y + 13)
      if (chip) drawMemoryChip(chip)
      else if (kept) drawPip(x + 7, y + h - 7, memoryTone(kept), true)
      if (dusty) drawHatch(x, y, w, hFull, radius)
      ctx.globalAlpha = base
    }

    // A source's written face closer in: its title, the middle face under it
    // in ForeverLM's voice, and in detail up to three near points and then
    // who and when. A line that does not fit is left out (the points first,
    // then the middle face), never run over the card's foot; a title's second
    // line gives way to the middle face's first.
    function drawFaceText(node, face, L, tx, cy, tw, bottom, titleFont, tf, showSub, tint) {
      const c = state.colors
      const lh = tf + 4
      const subH = L >= 3 && showSub ? 19 : 0
      const room = bottom - cy - subH
      let titleMax = Math.max(1, Math.min(2, Math.floor(room / lh)))
      if (face.mid && titleMax === 2 && room - 2 * lh - 3 < 16) titleMax = 1
      const titleLines = wrapLines(node.title, titleFont, tw, titleMax)
      ctx.fillStyle = c.text; ctx.font = titleFont
      drawLines(titleLines, tx, cy, lh)
      cy += titleLines.length * lh + 3
      const voice = 'italic 12px ' + state.font
      if (face.mid) {
        const room = Math.min(3, Math.floor((bottom - cy - subH) / 16))
        if (room > 0) {
          const lines = wrapLines('✦ ' + face.mid, voice, tw, room)
          ctx.font = voice; ctx.fillStyle = c.sub
          drawLines(lines, tx, cy, 16)
          cy += lines.length * 16 + 4
        }
      }
      if (L < 3) return
      for (const point of face.near.slice(0, 3)) {
        const room = Math.min(2, Math.floor((bottom - cy - subH) / 16))
        if (room < 1) break
        const lines = wrapLines(point, voice, tw - 12, room)
        ctx.font = voice
        ctx.fillStyle = c.ai; ctx.fillText('•', tx + 1, cy)
        ctx.fillStyle = c.sub; drawLines(lines, tx + 12, cy, 16)
        cy += lines.length * 16 + 2
      }
      if (subH && bottom - cy >= 15) {
        ctx.fillStyle = tint
        ctx.beginPath(); ctx.arc(tx + 3, cy + 7, 3, 0, Math.PI * 2); ctx.fill()
        ctx.fillStyle = c.sub; ctx.font = '12px ' + state.font
        drawLines(wrapLines(node.sub || TYPE_NAMES[node.type] || 'Source', ctx.font, tw - 11, 1), tx + 11, cy, 15)
      }
    }

    // A source or Doc under its Idea: a small flat card with its kind's dot
    // and its title.
    function drawEvidenceCard(node, L, W, H) {
      const c = state.colors
      const s = state.scale
      const p = pos(node)
      if (!p) return
      const x = p[0] * s + state.ox, y = p[1] * s + state.oy
      const w = EV_W * s, h = EV_H * s
      if (x > W || y > H || x + w < 0 || y + h < 0) return
      const mark = markOf(node.ref)
      const base = ctx.globalAlpha
      ctx.globalAlpha = base * (state.highlight.size && !state.highlight.has(node.ref) ? 0.3 : 1) * (mark && mark.dusty ? DUSTY_ALPHA : 1)
      ctx.fillStyle = c.card
      roundRect(x, y, w, h, Math.max(2, 8 * s)); ctx.fill()
      ctx.strokeStyle = state.selection.has(node.ref) ? c.select : c.hairline
      ctx.lineWidth = state.selection.has(node.ref) ? 2 : 1
      ctx.stroke()
      const pad = Math.max(4, 9 * s)
      const kept = mark && mark.cards > 0 && L > 0 && h > 22
      if (w - pad * 2 > 30 && h > 18) {
        ctx.fillStyle = TYPE_TINTS[node.type] || TYPE_TINTS.other
        ctx.beginPath(); ctx.arc(x + pad + 3, y + pad + 6, 3, 0, Math.PI * 2); ctx.fill()
        ctx.fillStyle = c.text
        ctx.font = '500 11px ' + state.font
        const lines = Math.max(1, Math.min(3, Math.floor((h - pad * 1.4 - (kept ? 10 : 0)) / 14)))
        ctx.save(); roundRect(x, y, w, h, Math.max(2, 8 * s)); ctx.clip()
        drawLines(wrapLines(node.title, ctx.font, w - pad * 2 - 10, lines), x + pad + 10, y + pad, 14)
        ctx.restore()
      }
      // How its kept cards stand, as a pip at its foot.
      if (kept) drawPip(x + 7, y + h - 7, memoryTone(mark), true)
      if (mark && mark.dusty) drawHatch(x, y, w, h, Math.max(2, 8 * s))
      ctx.globalAlpha = base
    }

    // From an Idea to its evidence: a stem down to the cards under it, and a
    // soft thread to each one the learner placed elsewhere.
    function drawEvidenceThreads(L) {
      if (state.lens || L === 0) return
      const c = state.colors
      ctx.strokeStyle = withAlpha(c.edge, 0.55); ctx.lineWidth = 1.2; ctx.lineCap = 'round'
      for (const [ideaRef, refs] of state.evidence) {
        const idea = placedBox(ideaRef)
        if (!idea) continue
        const [ix, iy] = toScreen(idea.x + idea.w / 2, idea.y + idea.h)
        let fanned = false
        for (const ref of refs) {
          const f = state.fan.get(ref)
          if (f && f.idea === ideaRef) { fanned = true; continue }
          const placed = placedBox(ref)
          if (!placed) continue
          const [bx, by] = toScreen(placed.x + placed.w / 2, placed.y + placed.h / 2)
          const set = focusSet()
          const keep = ctx.globalAlpha
          if (set && !state.selection.has(ideaRef) && !state.selection.has(ref)) ctx.globalAlpha = keep * FOCUS_DIM
          ctx.setLineDash([1, 5])
          ctx.beginPath(); ctx.moveTo(ix, iy - idea.h * state.scale / 2); ctx.lineTo(bx, by); ctx.stroke()
          ctx.setLineDash([])
          ctx.globalAlpha = keep
        }
        if (fanned) {
          ctx.beginPath(); ctx.moveTo(ix, iy); ctx.lineTo(ix, iy + 18 * state.scale); ctx.stroke()
        }
      }
      ctx.lineCap = 'butt'
    }

    // A proposed arrow is a gentle curve between two cards' edges (cards drawn
    // at `pa` and `pb`, their top-left corners).
    function curveBetween(pa, pb, ha, hb) {
      const [ax, ay] = pa, [bx, by] = pb
      ha = ha || CARD_H; hb = hb || CARD_H
      const ca = [ax + CARD_W / 2, ay + ha / 2], cb = [bx + CARD_W / 2, by + hb / 2]
      const p = clipToCard(ca, cb, ha), q = clipToCard(cb, ca, hb)
      const mx = (p[0] + q[0]) / 2, my = (p[1] + q[1]) / 2
      const dx = q[0] - p[0], dy = q[1] - p[1]
      const len = Math.hypot(dx, dy) || 1
      const bend = Math.min(60, len * 0.12)
      return [p, [mx - (dy / len) * bend, my + (dx / len) * bend], q]
    }
    function clipToRect(c, o, hw, hh) {
      const dx = o[0] - c[0], dy = o[1] - c[1]
      const k = Math.min(Math.abs(hw / (dx || 1e-6)), Math.abs(hh / (dy || 1e-6)), 1)
      return [c[0] + dx * k, c[1] + dy * k]
    }
    function clipToCard(c, o, h) {
      const dx = o[0] - c[0], dy = o[1] - c[1]
      const k = Math.min(Math.abs((CARD_W / 2 + 8) / (dx || 1e-6)), Math.abs(((h || CARD_H) / 2 + 8) / (dy || 1e-6)), 1)
      return [c[0] + dx * k, c[1] + dy * k]
    }
    function curvePoint(p, m, q, t) {
      const u = 1 - t
      return [u * u * p[0] + 2 * u * t * m[0] + t * t * q[0], u * u * p[1] + 2 * u * t * m[1] + t * t * q[1]]
    }

    // ---- Arrows
    //
    // An arrow joins two ends, each a card on the plane or a region
    // (`region:<id>`). Its route is a curve (the default, a gentle quadratic), a
    // straight line or an elbow; it may be dashed, take one of the eight
    // colours, and have its head at its end, at both ends or at neither. A
    // mind map's branch (`tree`) is an S-curve from the parent's right middle
    // to the child's left middle: no head, a little thicker.
    const DASH = [6, 5]
    function shownRegion(id) {
      const r = state.regions[id]
      if (!r) return null
      const pr = state.previewRegion
      if (pr && pr.id === id) return Object.assign({}, r, pr)
      return { x: r.x, y: r.y, w: shownW(r), h: shownH(r) }
    }
    // An arrow's end as a world rect, or null when it is not drawn (a card a
    // folded region hides, a region folded away or not there).
    function endRect(ref) {
      if (String(ref).startsWith('region:')) {
        const id = ref.slice(7)
        if (state.lens || hidden().regions.has(id)) return null
        const r = shownRegion(id)
        return r && { x: r.x, y: r.y, w: r.w, h: r.h }
      }
      const node = state.byRef.get(ref)
      const p = node && pos(node)
      if (!p) return null
      const [w, h] = sizeOf(node)
      return { x: p[0], y: p[1], w, h }
    }
    // Where the line from a box's middle toward `o` leaves the box (a gap off it).
    function boxEdge(c, o, b) {
      const dx = o[0] - c[0], dy = o[1] - c[1]
      const k = Math.min(Math.abs((b.w / 2 + 8) / (dx || 1e-6)), Math.abs((b.h / 2 + 8) / (dy || 1e-6)), 1)
      return [c[0] + dx * k, c[1] + dy * k]
    }
    function cubicPoint(p0, p1, p2, p3, t) {
      const u = 1 - t
      return [u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
        u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]]
    }
    function polyMid(pts) {
      let total = 0
      for (let i = 1; i < pts.length; i++) total += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
      let walk = total / 2
      for (let i = 1; i < pts.length; i++) {
        const seg = Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
        if (walk <= seg || i === pts.length - 1) { const k = seg ? walk / seg : 0; return [pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * k, pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * k] }
        walk -= seg
      }
      return pts[0]
    }
    // ---- Bundles (the brace)
    //
    // Two or more arrows into one card from the same side of it (the side the
    // straight line from the other end's middle enters by), of one colour,
    // dashing and head, are drawn converging: each a cubic from its start to a
    // junction 28 points off the middle of that side, arriving along the side's
    // outward normal, and one stem from the junction to the card with one head.
    // Only default curves with the end head join a bundle, never a branch or an
    // end on a region. Worked out once per layout: `invalidate` (and, while
    // cards slide, each frame) drops the cache.
    const SIDE_NORMALS = { left: [-1, 0], right: [1, 0], top: [0, -1], bottom: [0, 1] }
    function entrySide(a, b) {
      const dx = a.x + a.w / 2 - (b.x + b.w / 2), dy = a.y + a.h / 2 - (b.y + b.h / 2)
      // The offset against the box's own proportions, so a wide box takes the top and bottom more often.
      return Math.abs(dx) * b.h >= Math.abs(dy) * b.w ? (dx < 0 ? 'left' : 'right') : (dy < 0 ? 'top' : 'bottom')
    }
    function bundles() {
      if (state.bundleCache) return state.bundleCache
      const out = { byEdge: new Map(), list: [], routes: new Map(), grid: null }
      const groups = new Map()
      for (const e of Object.values(state.edges)) {
        if (e.tree || (e.route && e.route !== 'curve') || (e.heads && e.heads !== 'end')) continue
        if (String(e.from).startsWith('region:') || String(e.to).startsWith('region:') || !edgeShown(e)) continue
        const a = endRect(e.from), b = endRect(e.to)
        if (!a || !b) continue
        const side = entrySide(a, b)
        const key = [e.to, side, edgeColor(e), !!e.dashed].join('|')
        if (!groups.has(key)) groups.set(key, { side, b, color: edgeColor(e), dashed: !!e.dashed, members: [] })
        groups.get(key).members.push({ e, a })
      }
      for (const g of groups.values()) {
        if (g.members.length < 2) continue
        const n = SIDE_NORMALS[g.side]
        const mid = [g.b.x + g.b.w / 2 + n[0] * g.b.w / 2, g.b.y + g.b.h / 2 + n[1] * g.b.h / 2]
        const junction = [mid[0] + n[0] * JUNCTION, mid[1] + n[1] * JUNCTION]
        // The stem ends a gap off the card, as every arrow does.
        const bundle = { side: g.side, junction, tip: [mid[0] + n[0] * 8, mid[1] + n[1] * 8], color: g.color, dashed: g.dashed, edges: g.members.map(m => m.e.id) }
        for (const { e, a } of g.members) {
          const p0 = boxEdge([a.x + a.w / 2, a.y + a.h / 2], junction, a)
          const dx = junction[0] - p0[0], dy = junction[1] - p0[1]
          const d = Math.hypot(dx, dy) || 1
          const k = Math.max(20, d * 0.4)
          // It leaves toward the junction and arrives along the side's outward normal.
          const p1 = [p0[0] + dx / d * k, p0[1] + dy / d * k], p2 = [junction[0] + n[0] * k, junction[1] + n[1] * k]
          out.byEdge.set(e.id, { kind: 'cubic', pts: [p0, p1, p2, junction], mid: cubicPoint(p0, p1, p2, junction, 0.5), bundle })
        }
        out.list.push(bundle)
      }
      return (state.bundleCache = out)
    }

    // The route an arrow takes, in world points: {kind: quad | cubic | poly, pts, mid}.
    function edgePath(e) {
      const a = endRect(e.from), b = endRect(e.to)
      if (!a || !b) return null
      const bundled = bundles().byEdge.get(e.id)
      if (bundled) return bundled
      if (e.tree) {
        const p0 = [a.x + a.w, a.y + a.h / 2], p3 = [b.x, b.y + b.h / 2]
        const k = Math.max(24, Math.abs(p3[0] - p0[0]) * 0.5)
        const p1 = [p0[0] + k, p0[1]], p2 = [p3[0] - k, p3[1]]
        return { kind: 'cubic', pts: [p0, p1, p2, p3], mid: cubicPoint(p0, p1, p2, p3, 0.5) }
      }
      const ca = [a.x + a.w / 2, a.y + a.h / 2], cb = [b.x + b.w / 2, b.y + b.h / 2]
      if (e.route === 'elbow') {
        // Two legs and a crossing: out of the side facing the other end along the
        // longer axis, across at the midpoint, in at the facing side.
        const dx = cb[0] - ca[0], dy = cb[1] - ca[1]
        let pts = null
        if (Math.abs(dx) >= Math.abs(dy)) {
          const s = dx >= 0 ? 1 : -1
          const sx = s > 0 ? a.x + a.w + 8 : a.x - 8, ex = s > 0 ? b.x - 8 : b.x + b.w + 8
          if ((ex - sx) * s > 16) { const mx = (sx + ex) / 2; pts = [[sx, ca[1]], [mx, ca[1]], [mx, cb[1]], [ex, cb[1]]] }
        } else {
          const s = dy >= 0 ? 1 : -1
          const sy = s > 0 ? a.y + a.h + 8 : a.y - 8, ey = s > 0 ? b.y - 8 : b.y + b.h + 8
          if ((ey - sy) * s > 16) { const my = (sy + ey) / 2; pts = [[ca[0], sy], [ca[0], my], [cb[0], my], [cb[0], ey]] }
        }
        if (pts) return { kind: 'poly', pts, mid: polyMid(pts) }
      }
      const p = boxEdge(ca, cb, a), q = boxEdge(cb, ca, b)
      if (e.route === 'straight') return { kind: 'poly', pts: [p, q], mid: [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2] }
      const all = bundles()
      // The region names an arrow bends round are drawn at one size on the
      // screen, so they are larger on the plane the further out the camera
      // is: routes are found again when the zoom crosses a step (`headerZoom`).
      const z = headerZoom()
      if (all.grid && all.grid.z !== z) { all.grid = null; all.routes.clear() }
      const cache = all.routes
      const known = cache.get(e.id)
      if (known) return known
      const route = curveAround(e, a, b, ca, cb, p, q)
      cache.set(e.id, route)
      return route
    }

    // The default curve: a gentle bend to one side, unless that runs across
    // cards the arrow does not join; then the least bend either way that
    // clears them (or, when none does, crosses the fewest), so an arrow goes
    // round the cards between its ends instead of under them. Only the cards
    // near the arrow are looked at, once per layout (`bundles`).
    const CURVE_BENDS = [120, 200, 300, 420]
    function curveAround(e, a, b, ca, cb, p, q) {
      const mx = (p[0] + q[0]) / 2, my = (p[1] + q[1]) / 2
      const dx = q[0] - p[0], dy = q[1] - p[1]
      const len = Math.hypot(dx, dy) || 1
      const base = Math.min(60, len * 0.12)
      // A curve bent round cards leaves and meets its ends on the side it
      // bends to, so it climbs clear of a neighbour instead of grazing it.
      const curve = (bend, outward) => {
        const m = [mx - (dy / len) * bend, my + (dx / len) * bend]
        const from = outward ? boxEdge(ca, m, a) : p, to = outward ? boxEdge(cb, m, b) : q
        return { kind: 'quad', pts: [from, m, to], mid: curvePoint(from, m, to, 0.5) }
      }
      // A point every 60 units: a card is at least 120 across, so none is stepped over.
      const steps = Math.round(clamp(len / 60, 16, 80))
      const first = curve(base, false)
      // While cards slide or are dragged the cache is rebuilt every frame, so
      // arrows take the plain curve and find their way round once it settles.
      if (state.moves.size > 0 || (state.drag && state.drag.moved)) return first
      const grid = cardGrid()
      // How many of the route's points fall on a card it does not join,
      // giving up once it is past `limit`.
      const crossings = (route, limit) => {
        let n = 0
        for (let i = 1; i < steps; i++) {
          const [x, y] = curvePoint(route.pts[0], route.pts[1], route.pts[2], i / steps)
          const cell = grid.cells.get(cellKey(Math.floor(x / grid.size), Math.floor(y / grid.size)))
          if (!cell) continue
          for (const r of cell) {
            if (r.ref === e.from || r.ref === e.to) continue
            if (x > r.x - 6 && x < r.x + r.w + 6 && y > r.y - 6 && y < r.y + r.h + 6) { n++; break }
          }
          if (n > limit) return n
        }
        return n
      }
      let best = first, fewest = crossings(first, Infinity)
      if (!fewest) return first
      for (const size of CURVE_BENDS) {
        for (const bend of [size, -size]) {
          const route = curve(bend, true)
          const n = crossings(route, fewest - 1)
          if (!n) return route
          if (n < fewest) { best = route; fewest = n }
        }
      }
      return best
    }
    // The zoom a region's name is measured at, in three steps: full size
    // close in, then larger on the plane as the camera draws back, until the
    // regions fold into their faces (`foldK`).
    function headerZoom() { return state.scale >= 0.85 ? 1 : state.scale >= 0.65 ? 0.75 : 0.55 }
    function cellKey(cx, cy) { return cx * 1048576 + cy }
    // The placed cards as drawn, in cells of the plane, once per layout: a
    // point of a route looks only at the cards of its own cell.
    function cardGrid() {
      const cache = bundles()
      if (cache.grid) return cache.grid
      const size = 300
      const cells = new Map()
      const add = r => {
        for (let cx = Math.floor((r.x - 6) / size); cx <= Math.floor((r.x + r.w + 6) / size); cx++) {
          for (let cy = Math.floor((r.y - 6) / size); cy <= Math.floor((r.y + r.h + 6) / size); cy++) {
            const key = cellKey(cx, cy)
            if (!cells.has(key)) cells.set(key, [])
            cells.get(key).push(r)
          }
        }
      }
      for (const node of state.nodes) {
        if (!shown(node) || hiddenInStack(node)) continue
        const at = pos(node)
        if (!at) continue
        const [w, h] = sizeOf(node)
        add({ ref: node.ref, x: at[0], y: at[1], w, h })
      }
      // A region's name and summary sit just above its frame (`regionHeader`);
      // an arrow bends round them as round a card, taken with a two-line
      // summary at the zoom step the camera is at. An arrow to the region
      // itself may meet them. The check of a canvas routes the same way at
      // full size (`KnowledgeMapLint.headerRect`).
      const z = headerZoom()
      for (const r of shownRegions()) add({ ref: 'region:' + r.id, x: r.x, y: r.y - 60 / z, w: Math.min(r.w, 560 / z), h: 56 / z })
      return (cache.grid = { size, cells, z })
    }
    // The route as a polyline in world points, for hit tests.
    function pathSamples(path) {
      if (path.kind === 'poly') return path.pts
      const out = []
      for (let i = 0; i <= 16; i++) out.push(path.kind === 'quad' ? curvePoint(path.pts[0], path.pts[1], path.pts[2], i / 16) : cubicPoint(path.pts[0], path.pts[1], path.pts[2], path.pts[3], i / 16))
      return out
    }
    // The direction the line travels at its two ends, for the heads.
    function endAngles(path) {
      const p = path.pts
      if (path.kind === 'quad') return [Math.atan2(p[0][1] - p[1][1], p[0][0] - p[1][0]), Math.atan2(p[2][1] - p[1][1], p[2][0] - p[1][0])]
      if (path.kind === 'cubic') return [Math.atan2(p[0][1] - p[1][1], p[0][0] - p[1][0]), Math.atan2(p[3][1] - p[2][1], p[3][0] - p[2][0])]
      const n = p.length
      return [Math.atan2(p[0][1] - p[1][1], p[0][0] - p[1][0]), Math.atan2(p[n - 1][1] - p[n - 2][1], p[n - 1][0] - p[n - 2][0])]
    }
    function drawHead(x, y, ang, size) {
      ctx.beginPath(); ctx.moveTo(x, y)
      ctx.lineTo(x - size * Math.cos(ang - 0.42), y - size * Math.sin(ang - 0.42))
      ctx.lineTo(x - size * Math.cos(ang + 0.42), y - size * Math.sin(ang + 0.42))
      ctx.closePath(); ctx.fill()
    }
    // A branch takes its region's tint, unless it was given a colour.
    function treeTint(e) {
      const branch = stackLayout().branchTint.get(e.to)
      if (branch) return branch
      const id = stackLayout().innermost.get(e.to)
      const r = id && state.regions[id]
      return r && r.color ? r.color : null
    }
    // An arrow's colour: its own, else its stance's (green for, red against),
    // else a branch's tint, else the edge colour.
    function stanceTint(e) {
      return e.stance === 'supports' ? state.colors.memSolid : e.stance === 'contradicts' ? state.colors.contra : null
    }
    function edgeColor(e) { return e.color || stanceTint(e) || (e.tree ? treeTint(e) : null) || state.colors.edge }
    // Whether an arrow shows at all: both ends there, and in a lens only
    // between cards the lens shows.
    function edgeShown(e) {
      if (!state.lens) return true
      const a = state.byRef.get(e.from), b = state.byRef.get(e.to)
      return !!(a && b && inLens(a) && inLens(b))
    }

    function drawEdges(L) {
      const c = state.colors
      const list = Object.values(state.edges)
      if (!list.length) return
      if (L === 0 && !state.lens) {
        const bundles = new Map()
        for (const e of list) {
          const ra = regionOf(e.from), rb = regionOf(e.to)
          if (!ra || !rb || ra === rb) continue
          const key = [ra.id, rb.id].sort().join('|')
          bundles.set(key, (bundles.get(key) || 0) + 1)
        }
        for (const [key, count] of bundles) {
          const [a, b] = key.split('|').map(id => state.regions[id])
          if (Math.min(a.w, b.w) * state.scale < 90) continue
          const [x1, y1] = toScreen(a.x + a.w / 2, a.y + a.h / 2)
          const [x2, y2] = toScreen(b.x + b.w / 2, b.y + b.h / 2)
          ctx.strokeStyle = c.edge; ctx.lineWidth = 1 + count; ctx.lineCap = 'round'
          ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); ctx.lineCap = 'butt'
          pill(count + (count === 1 ? ' arrow' : ' arrows'), (x1 + x2) / 2, (y1 + y2) / 2, false)
        }
      }
      if (L === 0) return
      const W = viewW(), H = viewH()
      const base = ctx.globalAlpha
      for (const e of list) {
        if (!edgeShown(e)) continue
        const path = edgePath(e)
        if (!path) continue
        const pts = path.pts.map(pt => toScreen(pt[0], pt[1]))
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
        for (const pt of pts) { minX = Math.min(minX, pt[0]); minY = Math.min(minY, pt[1]); maxX = Math.max(maxX, pt[0]); maxY = Math.max(maxY, pt[1]) }
        if (minX > W + 40 || minY > H + 40 || maxX < -40 || maxY < -40) continue
        const selected = state.selectedEdge === e.id
        ctx.globalAlpha = base * focusDim(e)
        const color = selected ? c.select : edgeColor(e)
        ctx.strokeStyle = color; ctx.fillStyle = color
        ctx.lineWidth = e.tree ? (selected ? 2.8 : 2) : selected ? 2.2 : 1.6
        ctx.lineCap = e.dashed ? 'butt' : 'round'; ctx.lineJoin = 'round'
        if (e.dashed) ctx.setLineDash(DASH)
        ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1])
        if (path.kind === 'quad') ctx.quadraticCurveTo(pts[1][0], pts[1][1], pts[2][0], pts[2][1])
        else if (path.kind === 'cubic') ctx.bezierCurveTo(pts[1][0], pts[1][1], pts[2][0], pts[2][1], pts[3][0], pts[3][1])
        else for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1])
        ctx.stroke(); ctx.setLineDash([]); ctx.lineCap = 'butt'; ctx.lineJoin = 'miter'
        // A bundled arrow ends at its junction: the stem, drawn once, has the head.
        const heads = e.tree || path.bundle ? 'none' : e.heads === 'both' || e.heads === 'none' ? e.heads : 'end'
        if (heads !== 'none') {
          const [startAng, endAng] = endAngles({ kind: path.kind, pts })
          drawHead(pts[pts.length - 1][0], pts[pts.length - 1][1], endAng, 10)
          if (heads === 'both') drawHead(pts[0][0], pts[0][1], startAng, 10)
        }
        if (e.label && L >= 2) {
          const mid = toScreen(path.mid[0], path.mid[1])
          const box = pill(e.label, mid[0], mid[1], selected)
          state.edgePills.push({ id: e.id, x: box.x, y: box.y, w: box.w, h: box.h })
        }
      }
      drawStems(base)
      ctx.globalAlpha = base
    }
    // One stem from each bundle's junction to its card, with the one head, as
    // visible as the most visible of its arrows.
    function drawStems(base) {
      for (const bd of bundles().list) {
        const [jx, jy] = toScreen(bd.junction[0], bd.junction[1]), [tx, ty] = toScreen(bd.tip[0], bd.tip[1])
        if (Math.max(jx, tx) < -40 || Math.min(jx, tx) > viewW() + 40 || Math.max(jy, ty) < -40 || Math.min(jy, ty) > viewH() + 40) continue
        ctx.globalAlpha = base * Math.max(...bd.edges.map(id => focusDim(state.edges[id])))
        ctx.strokeStyle = bd.color; ctx.fillStyle = bd.color
        ctx.lineWidth = 1.6; ctx.lineCap = bd.dashed ? 'butt' : 'round'
        if (bd.dashed) ctx.setLineDash(DASH)
        ctx.beginPath(); ctx.moveTo(jx, jy); ctx.lineTo(tx, ty); ctx.stroke()
        ctx.setLineDash([]); ctx.lineCap = 'butt'
        drawHead(tx, ty, Math.atan2(ty - jy, tx - jx), 10)
      }
    }

    function pill(text, cx, cy, selected) {
      const c = state.colors
      ctx.font = '500 11.5px ' + state.font
      const tw = ctx.measureText(text).width
      ctx.save()
      ctx.shadowColor = c.shadow; ctx.shadowBlur = 6; ctx.shadowOffsetY = 1
      ctx.fillStyle = c.card
      roundRect(cx - tw / 2 - 9, cy - 11, tw + 18, 22, 11); ctx.fill()
      ctx.restore()
      ctx.fillStyle = selected ? c.select : c.sub
      ctx.fillText(text, cx - tw / 2, cy - 6.5)
      return { x: cx - tw / 2 - 9, y: cy - 11, w: tw + 18, h: 22 }
    }

    function regionOf(ref) {
      const node = state.byRef.get(ref)
      if (!node || !isPlaced(node)) return null
      const [x, y] = basePos(node)
      const [cx, cy] = midOf(ref, { x, y })
      let best = null
      for (const r of Object.values(state.regions)) {
        if (cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h) {
          if (!best || r.w * r.h < best.w * best.h) best = r
        }
      }
      return best
    }
    // ---- Notebook frames
    //
    // A region linked to a notebook is the notebook on the plane: it takes the
    // notebook's name, draws the notebook's cards that are not placed anywhere
    // yet in its rows (flat, not lifted: the learner has not put them there),
    // and, zoomed out to the bigger story, reads as the notebook itself: its
    // name and its takeaways in place of its cards.
    function notebookOf(r) { return r && r.notebookID ? state.notebooks.get(r.notebookID) || null : null }
    function regionName(r) { const nb = notebookOf(r); return nb ? nb.title : (r.name || 'Untitled region') }

    // The paper a region holds when every card in it is a page or a figure or
    // passage clip of that one paper: {ref, byline}. Such a region is drawn as
    // the paper's banner, as the Library shows a paper (its picture, then its
    // authors, venue and year), instead of as a bare name.
    function paperOf(r) {
      if (notebookOf(r)) return null
      const refs = refsInRegion(r)
      if (!refs.length) return null
      let src = null, byline = ''
      for (const ref of refs) {
        const n = state.byRef.get(ref)
        if (!n || !n.src || (n.kind !== 'clip' && n.kind !== 'page')) return null
        if (src && n.src !== src) return null
        src = n.src; byline = n.byline || byline
      }
      return { ref: src, byline }
    }
    // The paper's first-page picture as a ready image, or null.
    function paperThumb(paper) {
      const img = paper && state.thumbs.get(paper.ref)
      return img && img.complete && img.naturalWidth ? img : null
    }
    // A picture contained in a box with rounded corners, a hairline round it.
    function drawPaperThumb(img, x, y, w, h) {
      const k = Math.min(w / img.naturalWidth, h / img.naturalHeight)
      const iw = img.naturalWidth * k, ih = img.naturalHeight * k
      const ix = x + (w - iw) / 2, iy = y + (h - ih) / 2
      ctx.save(); roundRect(ix, iy, iw, ih, 3); ctx.clip()
      ctx.drawImage(img, ix, iy, iw, ih)
      ctx.restore()
      ctx.strokeStyle = state.colors.hairline; ctx.lineWidth = 1
      roundRect(ix, iy, iw, ih, 3); ctx.stroke()
    }

    // ---- Regions inside regions
    //
    // One plane holds every level (product owner, 2026-10-09: "it can also just be
    // one big canvas"). A region drawn inside another is inside it: nothing is
    // stored for that, the rects say so. A card belongs to the innermost
    // region around it, a parent's count takes in its children's cards, and
    // moving a parent carries the regions inside it. Zoomed out, every region
    // folds into a face (its name, what it holds, the learner's own Ideas in
    // it); a region inside a folded one is drawn as a tile in its parent's
    // face until it is too small to read, when it fades and the parent's own
    // lines take its place. The chrome shows the path of regions that frame
    // the view, and ⌘↑ / ⌘↓ climb out and dive in.
    function regionTree() {
      if (state.regionTree) return state.regionTree
      const list = Object.values(state.regions)
      const parent = new Map(), children = new Map()
      for (const r of list) children.set(r.id, [])
      const inside = (a, b) => a.x >= b.x - 0.5 && a.y >= b.y - 0.5 && a.x + a.w <= b.x + b.w + 0.5 && a.y + a.h <= b.y + b.h + 0.5 && a.w * a.h < b.w * b.h
      for (const r of list) {
        let best = null
        for (const o of list) if (o !== r && inside(r, o) && (!best || o.w * o.h < best.w * best.h)) best = o
        parent.set(r.id, best ? best.id : null)
        if (best) children.get(best.id).push(r.id)
      }
      const depth = new Map()
      const depthOf = (id) => { if (depth.has(id)) return depth.get(id); const p = parent.get(id); const d = p ? depthOf(p) + 1 : 0; depth.set(id, d); return d }
      for (const r of list) depthOf(r.id)
      return (state.regionTree = { parent, children, depth })
    }
    function parentRegion(id) { const p = regionTree().parent.get(id); return p ? state.regions[p] || null : null }
    function childRegions(id) { return (regionTree().children.get(id) || []).map(cid => state.regions[cid]).filter(Boolean) }
    function descendantRegions(id) {
      const out = []
      const walk = (rid) => { for (const c of childRegions(rid)) { out.push(c); walk(c.id) } }
      walk(id)
      return out
    }
    function ancestorRegions(id) {
      const out = []
      for (let p = parentRegion(id); p; p = parentRegion(p.id)) out.unshift(p)
      return out
    }
    // How far a region inside another has shrunk away into its parent's face:
    // 0 while it is a tile wide enough to read (140 points on screen or
    // more), 1 once it is under 100, crossfading between. A region inside
    // none is always drawn.
    function tileK(r) {
      if (state.lens || !regionTree().parent.get(r.id)) return 0
      return clamp((140 - r.w * state.scale) / 40, 0, 1)
    }
    // The learner's own Ideas in a region (the innermost one around each),
    // top to bottom: what the region says in their words.
    function ideasIn(r) {
      const inner = stackLayout().innermost
      return state.nodes.filter(n => n.kind === 'idea' && inner.get(n.ref) === r.id)
        .map(n => ({ n, p: state.placements[n.ref] }))
        .sort((a, b) => (Math.abs(a.p.y - b.p.y) < CARD_H / 2 ? a.p.x - b.p.x : a.p.y - b.p.y))
        .map(x => x.n.title)
    }
    // The lines a folded region's face reads: its own Ideas, else the Ideas
    // of the regions inside it, else nothing (the model's gist is drawn then).
    function faceLines(r) {
      const own = ideasIn(r)
      if (own.length) return own
      const nested = []
      for (const c of descendantRegions(r.id)) nested.push(...ideasIn(c))
      return nested
    }
    // The regions that frame the view, outermost first: the innermost region
    // holding the view's middle that fills most of the view (the learner is
    // inside it), or is wholly in view and a third of it (they zoomed to it),
    // and the ones around it.
    function viewRegionPath() {
      if (state.lens) return []
      const [x0, y0] = toWorld(0, 0), [x1, y1] = toWorld(viewW(), viewH())
      const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
      const area = Math.max(1, (x1 - x0) * (y1 - y0))
      let best = null
      for (const r of Object.values(state.regions)) {
        if (cx < r.x || cx > r.x + r.w || cy < r.y || cy > r.y + r.h) continue
        const iw = Math.max(0, Math.min(x1, r.x + r.w) - Math.max(x0, r.x)), ih = Math.max(0, Math.min(y1, r.y + r.h) - Math.max(y0, r.y))
        const ofView = iw * ih / area, inView = iw * ih / Math.max(1, r.w * r.h)
        if (ofView < 0.55 && !(inView >= 0.8 && ofView >= 0.3)) continue
        if (!best || r.w * r.h < best.w * best.h) best = r
      }
      return best ? ancestorRegions(best.id).concat([best]) : []
    }
    // ⌘↑: out to the region around the one framing the view, or to everything.
    function climbOut() {
      const path = viewRegionPath()
      if (path.length >= 2) fitTo(paddedBounds(path[path.length - 2]))
      else fitTo(allBounds())
    }
    // ⌘↓ (and Return with a region selected): into the selected region, or the
    // first region inside the one framing the view.
    function diveIn() {
      const sel = state.selectedRegion && state.regions[state.selectedRegion]
      if (sel) { fitTo(paddedBounds(sel)); return }
      const path = viewRegionPath()
      const kids = path.length ? childRegions(path[path.length - 1].id) : Object.values(state.regions).filter(r => !regionTree().parent.get(r.id))
      const first = kids.sort((a, b) => (Math.abs(a.y - b.y) < CARD_H ? a.x - b.x : a.y - b.y))[0]
      if (first) { selectRegion(first.id); fitTo(paddedBounds(first)) }
    }

    // How far a region's cards have folded into its face: 0 while they read
    // (a card 130 points wide or more), 1 once they are tiles too small to
    // say anything (100 or less), crossfading between.
    function foldK() { return state.lens ? 0 : clamp((130 - CARD_W * state.scale) / 30, 0, 1) }
    // A card in a region (or drawn unplaced in a notebook's frame) folds away
    // with it; a card on the open plane never does.
    function folded(node) {
      const lay = stackLayout()
      return lay.frameOf.get(node.ref) || lay.innermost.get(node.ref) ? foldK() : 0
    }

    // The cards a region holds: those whose stored spot (or the other
    // window's drag) has their middle inside its stored frame. What is drawn
    // can differ (a folded series closes the region up), so membership is
    // never read from the drawn spot: a card drawn at the edge stays in.
    function refsInRegion(r) {
      const stored = state.regions[r.id]
      const h = stored ? Math.max(r.h, stored.h) : r.h
      const out = []
      const prev = state.preview
      // The placed cards only (a fifth of a big library): read where each one's middle is.
      for (const ref in state.placements) {
        const node = state.byRef.get(ref)
        if (!node) continue
        const q = state.placements[ref]
        const p = (prev && prev.get(ref)) || q
        const cx = p.x + (q.w > 0 && !state.lens ? clamp(q.w, MIN_CARD_W, MAX_CARD_W) : CARD_W) / 2
        const cy = p.y + (q.h > 0 || q.folded ? cardH(node) : CARD_H) / 2
        if (cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + h) out.push(ref)
      }
      // A notebook's frame also holds the notebook's cards it draws unplaced.
      for (const [ref, id] of stackLayout().frameOf) if (id === r.id && !state.placements[ref] && !out.includes(ref)) out.push(ref)
      return out
    }
    function centerIn(p, r, ref) {
      const [cx, cy] = midOf(ref, p)
      return cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h
    }

    // ---- Series stacks
    //
    // Inside a region, three or more cards of one series (a book's chapters, a
    // show's episodes, a course's lectures) fold into one stacked card in the
    // place of the first, and the region's other cards close up behind it.
    // Only what is drawn moves: the learner's placements stay as they are.
    const SERIES_WORDS = { book: ['chapter', 'chapters'], podcast: ['episode', 'episodes'], video: ['video', 'videos'], course: ['lecture', 'lectures'], meeting: ['session', 'sessions'] }
    function seriesWord(type, n) {
      const w = SERIES_WORDS[type] || ['item', 'items']
      return n + ' ' + (n === 1 ? w[0] : w[1])
    }
    // The layout as drawn. While cards are carried it is the layout they
    // would make if let go now (the other cards making room for them), and
    // before the pointer moves it is the layout at the press, held still.
    function stackLayout() {
      const d = state.drag
      if (d && d.kind === 'cards' && d.base) return d.preview || d.base
      if (!state.stackCache) state.stackCache = computeLayout(state.placements)
      return state.stackCache
    }
    // The regions laid out in rows (a notebook's frame, a region holding a
    // series) and the series stacked elsewhere, for a set of spots: the
    // learner's own, or, while cards are carried, the spots they would have if
    // let go now. The `carried` cards are read against the frames as drawn
    // (`drawnH`), so a card let go just below a frame stays out of it; the rest
    // against the frames as stored.
    // A mind map's region is as large as its tree, which can be larger than the
    // frame stored for it; the cards it holds are read against the larger of the
    // two, so a tree that has outgrown its frame does not lose cards from it.
    function computeLayout(placements, carried, drawnH, resizing, pinned) {
      let grow = null, out = null
      for (let pass = 0; pass < 3; pass++) {
        out = computeLayoutOnce(placements, carried, drawnH, resizing, grow, pinned)
        let again = false
        for (const [id, h] of out.regionH) {
          const r = state.regions[id]
          if (!r || r.layout !== 'tree') continue
          const cur = grow && grow.get(id)
          const needH = Math.max(r.h, h), needW = Math.max(r.w, out.regionW.get(id) || 0)
          if (needH > (cur ? cur.h : r.h) + 0.5 || needW > (cur ? cur.w : r.w) + 0.5) {
            if (!grow) grow = new Map()
            grow.set(id, { w: needW, h: needH })
            again = true
          }
        }
        if (!again) break
      }
      return out
    }
    function computeLayoutOnce(placements, carried, drawnH, resizing, grow, pinned) {
      // frameOf: each card drawn in a notebook's frame, by the frame's id.
      // innermost: each placed card's region, the innermost one around it.
      // branchTint: each mind-map card's branch colour (see `layoutTree`).
      const out = { pos: new Map(), stackOf: new Map(), stacks: [], regionH: new Map(), regionW: new Map(), members: new Map(), frameOf: new Map(), innermost: new Map(), fixedW: new Set(), branchTint: new Map() }
      if (state.lens) return out
      const regions = Object.values(state.regions)
      const heightOf = (r, ref) => {
        const base = carried && carried.has(ref) && drawnH && drawnH.has(r.id) ? drawnH.get(r.id) : r.h
        const g = grow && grow.get(r.id)
        return g ? Math.max(base, g.h) : base
      }
      const widthOf = (r) => { const g = grow && grow.get(r.id); return g ? Math.max(r.w, g.w) : r.w }
      for (const node of state.nodes) {
        const p = placements[node.ref]
        if (!p) continue
        const [cx, cy] = midOf(node.ref, p)
        let best = null
        for (const r of regions) {
          if (cx >= r.x && cx <= r.x + widthOf(r) && cy >= r.y && cy <= r.y + heightOf(r, node.ref) && (!best || r.w * r.h < best.w * best.h)) best = r
        }
        if (best) out.innermost.set(node.ref, best.id)
      }
      // The region being resized keeps the cards it held when the drag began,
      // so shrinking it re-flows them into more rows instead of leaving them
      // behind outside it.
      const held = resizing || (state.drag && state.drag.kind === 'resizeRegion' && state.drag.members
        ? { id: state.drag.id, refs: state.drag.members } : null)
      if (held) for (const ref of held.refs) if (placements[ref]) out.innermost.set(ref, held.id)
      // The cards of a mind map stay in it while another card is carried about
      // (their spots are where the tree draws them, which the frame may not hold).
      if (pinned) for (const [ref, id] of pinned) if (placements[ref] && state.regions[id]) out.innermost.set(ref, id)
      const claimed = new Set()
      for (const r of regions) {
        const nb = notebookOf(r)
        const members = []
        // A card in a region inside this one is that region's, not this one's.
        for (const node of state.nodes) {
          const p = placements[node.ref]
          if (!p || out.innermost.get(node.ref) !== r.id) continue
          members.push({ node, x: p.x, y: p.y })
        }
        // The notebook's cards the learner has not placed anywhere come after
        // the ones placed in the frame, in the notebook's order.
        const loose = []
        if (nb) for (const ref of nb.refs) {
          const node = state.byRef.get(ref)
          if (!node || placements[ref] || claimed.has(ref) || (state.preview && state.preview.has(ref))) continue
          claimed.add(ref)
          loose.push({ node, loose: true })
        }
        const byGroup = new Map()
        for (const m of members) if (m.node.group) {
          if (!byGroup.has(m.node.group)) byGroup.set(m.node.group, [])
          byGroup.get(m.node.group).push(m)
        }
        for (const m of loose) if (m.node.group) {
          if (!byGroup.has(m.node.group)) byGroup.set(m.node.group, [])
          byGroup.get(m.node.group).push(m)
        }
        const closed = new Set([...byGroup].filter(([g, list]) => list.length >= 3 && !state.openStacks.has(r.id + '|' + g)).map(([g]) => g))
        const open = new Set([...byGroup].filter(([g, list]) => list.length >= 3 && state.openStacks.has(r.id + '|' + g)).map(([g]) => g))
        // A paper's region (every card a page or a figure of that one paper)
        // lays its cards out in rows, as a notebook's frame does.
        const paperRegion = !nb && members.length > 0 && members.every(m =>
          (m.node.kind === 'clip' || m.node.kind === 'page') && m.node.src && m.node.src === members[0].node.src)
        if (r.layout === 'tree' && !nb && members.length) { layoutTree(r, members, out); continue }
        if (!nb && !paperRegion && !closed.size && !open.size) continue
        if (!members.length && !loose.length) continue
        // Reading order of the region as placed, the series kept together,
        // then the notebook's unplaced cards.
        members.sort((a, b) => (Math.abs(a.y - b.y) < CARD_H / 2 ? a.x - b.x : a.y - b.y))
        out.members.set(r.id, members.map(m => m.node.ref))
        if (nb) for (const m of members.concat(loose)) out.frameOf.set(m.node.ref, r.id)
        // The cards fill the frame's width in rows, inset as the learner's
        // first card is (within reason). The columns come from the width, never
        // from how many cards share the top row: a series set down on one spot
        // counts as one card there, and a row of them would run out of the frame.
        const padX = members.length ? clamp(Math.min(...members.map(m => m.x)) - r.x, 20, 80) : 50
        const padY = members.length ? clamp(Math.min(...members.map(m => m.y)) - r.y, 20, 90) : 60
        const x0 = r.x + padX, y0 = r.y + padY
        const cols = Math.max(1, Math.floor((r.w - padX * 2 + GAP) / (CARD_W + GAP)))
        const items = []
        const seen = new Set()
        for (const m of members.concat(loose)) {
          const g = m.node.group
          if (g && (closed.has(g) || open.has(g))) {
            if (seen.has(g)) continue
            seen.add(g)
            const list = byGroup.get(g).map(x => x.node).sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true }))
            if (closed.has(g)) items.push({ stack: { key: r.id + '|' + g, region: r.id, group: g, refs: list.map(n => n.ref), leader: list[0], title: list[0].groupTitle || '', type: list[0].type } })
            else { items.push({ openHead: { key: r.id + '|' + g, title: list[0].groupTitle || '', type: list[0].type, n: list.length, first: list[0].ref } }); for (const n of list) items.push({ node: n }) }
          } else items.push({ node: m.node })
        }
        // Each row as tall as its tallest card: a clip is as tall as its picture.
        const cells = items.filter(it => !it.openHead)
        const rowH = []
        cells.forEach((it, k) => {
          const row = Math.floor(k / cols)
          rowH[row] = Math.max(rowH[row] || 0, it.stack ? CARD_H : cardH(it.node))
        })
        const rowY = []
        for (let row = 0, y = y0; row < rowH.length; row++) { rowY[row] = y; y += rowH[row] + GAP }
        let i = 0
        for (const it of items) {
          if (it.openHead) { out.stacks.push({ openHead: it.openHead }); continue }
          const x = x0 + (i % cols) * (CARD_W + GAP), y = rowY[Math.floor(i / cols)]
          i++
          if (it.stack) {
            for (const ref of it.stack.refs) { out.pos.set(ref, [x, y]); out.stackOf.set(ref, it.stack); out.fixedW.add(ref) }
            out.stacks.push(it.stack)
          } else { out.pos.set(it.node.ref, [x, y]); out.fixedW.add(it.node.ref) }
        }
        // The frame hugs the cards as drawn: a folded series leaves no empty
        // band, and a series fanned out grows the frame rather than spilling.
        const tall = rowH.length ? rowH.reduce((a, b) => a + b + GAP, 0) - GAP : CARD_H
        out.regionH.set(r.id, padY + tall + Math.max(padY, 30))
      }
      // Anywhere else, a series set down on one spot (a stack dragged out of
      // its region) stays a stack.
      const piles = new Map()
      for (const node of state.nodes) {
        const p = placements[node.ref]
        if (!p || !node.group || out.pos.has(node.ref)) continue
        const key = node.group + '@' + Math.round(p.x / 24) + ',' + Math.round(p.y / 24)
        if (!piles.has(key)) piles.set(key, [])
        piles.get(key).push(node)
      }
      for (const [key, list] of piles) {
        if (list.length < 2 || state.openStacks.has(key)) continue
        list.sort((a, b) => a.title.localeCompare(b.title, undefined, { numeric: true }))
        const p = placements[list[0].ref]
        const st = { key, region: null, group: list[0].group, refs: list.map(n => n.ref), leader: list[0], title: list[0].groupTitle || '', type: list[0].type }
        for (const n of list) { out.pos.set(n.ref, [p.x, p.y]); out.stackOf.set(n.ref, st); out.fixedW.add(n.ref) }
        out.stacks.push(st)
      }
      return out
    }
    // ---- Mind maps
    //
    // A region whose `layout` is `tree` lays its cards out from the tree edges
    // among them (`tree: true`, parent to child): the roots (cards with no
    // parent in the region) stacked top to bottom at the region's left padding,
    // each child a column 60 to the right of its parent's right edge, siblings
    // stacked with a 24 gap in the order of their stored spots, a parent
    // centred on its children's block, subtrees never overlapping (the widths
    // are the cards' own). A card folded hides what hangs from it. The region
    // is as tall as the tree, and as wide when the tree is wider. Each child of
    // a root, in the order its branch is drawn, takes the next of the eight
    // tints after the region's own, and every card under it inherits it.
    const TREE_PAD_X = 40, TREE_PAD_Y = 36, TREE_COL = 60, TREE_GAP = 24, TREE_ROOT_GAP = 40
    function layoutTree(r, members, out) {
      const spot = new Map(members.map(m => [m.node.ref, m]))
      const { kids, parent } = treeIndex()
      const order = (a, b) => (a.y - b.y) || (a.x - b.x) || (a.node.ref < b.node.ref ? -1 : 1)
      const visible = (ref) => spot.has(ref) && !hiddenByFold(ref)
      const kidsOf = new Map(), size = new Map(), placed = new Set()
      const childrenOf = (ref) => (kids.get(ref) || []).filter(visible).map(k => spot.get(k)).sort(order).map(m => m.node.ref)
      const measure = (ref, trail) => {
        const node = spot.get(ref).node
        const own = cardH(node)
        const next = new Set(trail).add(ref)
        const ks = childrenOf(ref).filter(k => !next.has(k))
        kidsOf.set(ref, ks)
        let block = 0
        for (const k of ks) block += measure(k, next) + (block ? TREE_GAP : 0)
        size.set(ref, { total: Math.max(own, block), block })
        return size.get(ref).total
      }
      const x0 = r.x + TREE_PAD_X
      let right = x0
      const put = (ref, x, top) => {
        const node = spot.get(ref).node
        const { total, block } = size.get(ref)
        const own = cardH(node), w = cardW(node)
        placed.add(ref)
        out.pos.set(ref, [x, top + (total - own) / 2])
        right = Math.max(right, x + w)
        let y = top + (total - block) / 2
        for (const k of kidsOf.get(ref)) { put(k, x + w + TREE_COL, y); y += size.get(k).total + TREE_GAP }
      }
      const live = members.filter(m => visible(m.node.ref)).sort(order)
      const roots = live.filter(m => !visible(parent.get(m.node.ref) || '')).map(m => m.node.ref)
      let top = r.y + TREE_PAD_Y
      const stacked = []
      const stack = (ref) => { stacked.push(ref); measure(ref, new Set()); put(ref, x0, top); top += size.get(ref).total + TREE_ROOT_GAP }
      for (const ref of roots) stack(ref)
      // A cycle has no root: its cards are roots in their own right.
      for (const m of live) if (!placed.has(m.node.ref)) stack(m.node.ref)
      const start = REGION_TINTS.indexOf(r.color || REGION_TINTS[0])
      const tintDown = (ref, tint) => {
        if (out.branchTint.has(ref)) return
        out.branchTint.set(ref, tint)
        for (const k of kidsOf.get(ref) || []) tintDown(k, tint)
      }
      for (const root of stacked) (kidsOf.get(root) || []).forEach((k, i) => tintDown(k, REGION_TINTS[(start + 1 + i) % REGION_TINTS.length]))
      out.members.set(r.id, live.map(m => m.node.ref))
      const bottom = roots.length || live.length ? top - TREE_ROOT_GAP : r.y + TREE_PAD_Y
      out.regionH.set(r.id, bottom - r.y + TREE_PAD_Y)
      out.regionW.set(r.id, right - r.x + TREE_PAD_X)
    }

    // The spots the cards would have if let go now: the carried ones where
    // they are, and in every region laid out in rows the others where they are
    // drawn, so the order read is the order the learner sees.
    // The cards each mind map held when the press began, but for the carried ones.
    function pinnedTrees(d) {
      let pinned = null
      for (const [id, refs] of d.base.members) {
        const r = state.regions[id]
        if (!r || r.layout !== 'tree') continue
        if (!pinned) pinned = new Map()
        for (const ref of refs) if (!d.carrying.has(ref)) pinned.set(ref, id)
      }
      return pinned
    }
    function carriedPlacements(d) {
      const out = Object.assign({}, state.placements)
      for (const refs of d.base.members.values()) {
        for (const ref of refs) {
          if (d.carrying.has(ref) || !out[ref]) continue
          const p = d.base.pos.get(ref)
          if (p) out[ref] = { x: p[0], y: p[1] }
        }
      }
      return out
    }
    // The smallest region a card at `p` would be in, read against the frames
    // as drawn.
    function regionAt(p, ref) {
      let best = null
      for (const r of shownRegions()) {
        if (centerIn(p, r, ref) && (!best || r.w * r.h < best.w * best.h)) best = r
      }
      return best ? best.id : null
    }

    // Free cards carried near others line up with them, as in Freeform: an
    // edge or the middle of what is carried meets one of a neighbour's, or
    // keeps the usual gap beside it, within a few points, and a guide shows the
    // line. Holding ⌘ carries them freely.
    function snapCarried(d, dx, dy) {
      d.guides = []
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
      for (const st of d.starts) {
        x0 = Math.min(x0, st.p[0] + dx); y0 = Math.min(y0, st.p[1] + dy)
        const sn = state.byRef.get(st.ref)
        x1 = Math.max(x1, st.p[0] + dx + cardW(sn)); y1 = Math.max(y1, st.p[1] + dy + cardH(sn))
      }
      if (x0 === Infinity) return [dx, dy]
      const T = 6 / state.scale
      const [vx0, vy0] = toWorld(0, 0), [vx1, vy1] = toWorld(viewW(), viewH())
      const mine = { x: [x0, (x0 + x1) / 2, x1], y: [y0, (y0 + y1) / 2, y1] }
      let bx = null, by = null
      let looked = 0
      for (const node of state.nodes) {
        if (d.carrying.has(node.ref) || !state.placements[node.ref] || hiddenInStack(node) || isFanned(node)) continue
        const p = pos(node)
        const nh = cardH(node), nw = sizeOf(node)[0]
        if (!p || p[0] > vx1 || p[0] + nw < vx0 || p[1] > vy1 || p[1] + nh < vy0) continue
        if (++looked > 400) break
        const theirs = { x: [p[0], p[0] + nw / 2, p[0] + nw], y: [p[1], p[1] + nh / 2, p[1] + nh] }
        // Same edge to same edge, middle to middle, and side by side a gap apart.
        const xs = [[0, theirs.x[0]], [1, theirs.x[1]], [2, theirs.x[2]], [0, theirs.x[2] + GAP], [2, theirs.x[0] - GAP]]
        const ys = [[0, theirs.y[0]], [1, theirs.y[1]], [2, theirs.y[2]], [0, theirs.y[2] + GAP], [2, theirs.y[0] - GAP]]
        for (const [i, line] of xs) {
          const e = line - mine.x[i]
          if (Math.abs(e) < T && (!bx || Math.abs(e) < Math.abs(bx.e))) bx = { e, line, a: Math.min(y0, p[1]), b: Math.max(y1, p[1] + nh), i }
        }
        for (const [i, line] of ys) {
          const e = line - mine.y[i]
          if (Math.abs(e) < T && (!by || Math.abs(e) < Math.abs(by.e))) by = { e, line, a: Math.min(x0, p[0]), b: Math.max(x1, p[0] + nw), i }
        }
      }
      if (bx) {
        dx += bx.e
        const x = mine.x[bx.i] + bx.e
        d.guides.push({ x1: x, y1: Math.min(bx.a, y0 + (by ? by.e : 0)) - 12, x2: x, y2: Math.max(bx.b, y1 + (by ? by.e : 0)) + 12 })
      }
      if (by) {
        dy += by.e
        const y = mine.y[by.i] + by.e
        d.guides.push({ x1: Math.min(by.a, x0 + (bx ? bx.e : 0)) - 12, y1: y, x2: Math.max(by.b, x1 + (bx ? bx.e : 0)) + 12, y2: y })
      }
      return [dx, dy]
    }

    function stackOf(node) { return stackLayout().stackOf.get(node.ref) || null }
    function hiddenInStack(node) { const st = stackOf(node); return !!st && st.leader.ref !== node.ref }

    // A folded series: the top card with two cards showing behind it, the
    // series' picture, its name and how many it holds.
    function drawStack(st, L, W, H) {
      const c = state.colors
      const s = state.scale
      const p = pos(st.leader)
      if (!p) return
      const x = p[0] * s + state.ox, y = p[1] * s + state.oy
      const w = CARD_W * s, h = CARD_H * s
      if (x > W || y > H || x + w + 12 < 0 || y + h + 12 < 0) return
      const radius = Math.max(2, 12 * s)
      const selected = st.refs.some(ref => state.selection.has(ref))
      const tint = TYPE_TINTS[st.type] || TYPE_TINTS.other
      const off = Math.max(2.5, Math.min(7, 7 * s))
      // How the kept cards about the series stand, all its items together;
      // a series being forgotten is faint and dusty, as a card is.
      const mem = state.memory.enabled ? sumMarks(st.refs) : null
      if (mem && mem.dusty) ctx.globalAlpha *= DUSTY_ALPHA
      // The cards behind.
      for (const k of [2, 1]) {
        ctx.fillStyle = k === 2 ? withAlpha(tint, state.dark ? 0.18 : 0.10) : c.card
        roundRect(x + off * k, y + off * k, w, h, radius); ctx.fill()
        ctx.strokeStyle = c.hairline; ctx.lineWidth = 1; ctx.stroke()
      }
      // The top card.
      ctx.save()
      ctx.shadowColor = c.shadow
      ctx.shadowBlur = state.lifting ? 30 : Math.min(16, 12 * Math.max(0.5, s))
      ctx.shadowOffsetY = state.lifting ? 12 : Math.min(3, 3 * Math.max(0.5, s))
      ctx.fillStyle = c.card
      roundRect(x, y, w, h, radius); ctx.fill()
      ctx.restore()
      if (selected) { ctx.strokeStyle = c.select; ctx.lineWidth = 2; roundRect(x - 3, y - 3, w + 6 + off * 2, h + 6 + off * 2, radius + 3); ctx.stroke() }
      else if (st.refs.includes(state.hover) && !state.drag) { ctx.strokeStyle = withAlpha(c.select, 0.45); ctx.lineWidth = 1.5; roundRect(x - 2, y - 2, w + 4 + off * 2, h + 4 + off * 2, radius + 2); ctx.stroke() }
      const label = seriesWord(st.type, st.refs.length)
      const kept = mem && mem.cards > 0 ? mem : null
      const dust = () => { if (mem && mem.dusty) drawHatch(x, y, w, h, radius) }
      if (L === 0) { dust(); return }
      const cover = st.refs.map(ref => state.byRef.get(ref)).find(n => n && state.thumbs.has(n.ref)) || null
      if (L === 1) {
        if (!(cover && drawThumb(cover, x, y, w, h, radius))) {
          ctx.fillStyle = withAlpha(tint, state.dark ? 0.22 : 0.12)
          roundRect(x, y, w, h, radius); ctx.fill()
          const tf = 10.5, titleFont = '600 ' + tf + 'px ' + state.font
          if (w - 12 >= 58 && h >= 30) {
            ctx.save(); roundRect(x, y, w, h, radius); ctx.clip()
            ctx.fillStyle = c.text; drawLines(wrapLines(st.title || label, titleFont, w - 12, 2), x + 6, y + 5, tf + 3)
            ctx.restore()
          }
        }
        // The count, as a badge on the corner.
        const badge = String(st.refs.length)
        ctx.font = '700 10px ' + state.font
        const bw = Math.max(16, ctx.measureText(badge).width + 9)
        ctx.fillStyle = tint
        roundRect(x + w - bw - 4, y + h - 18, bw, 14, 7); ctx.fill()
        ctx.fillStyle = '#fff'; ctx.fillText(badge, x + w - bw - 4 + (bw - ctx.measureText(badge).width) / 2, y + h - 16)
        if (kept) drawPip(x + 7, y + h - 7, memoryTone(kept), true)
        dust()
        return
      }
      const pad = Math.max(6, 14 * s)
      let left = x
      if (cover) {
        const side = h - pad * 1.2
        const tileW = side * (L === 2 ? 0.58 : 0.78)
        if (drawThumb(cover, x + pad * 0.6, y + pad * 0.6, tileW, side, Math.max(2, 6 * s))) left = x + pad * 0.6 + tileW - pad * 0.4
      }
      const chip = kept ? memoryChip(kept, x, y, h, L, pad) : null
      const tw = x + w - left - pad * 2
      if (tw < 24) { if (chip) drawMemoryChip(chip); dust(); return }
      ctx.save(); roundRect(x, y, w, h, radius); ctx.clip()
      const tf = L === 2 ? 13 : 14
      const titleFont = '600 ' + tf + 'px ' + state.font
      ctx.fillStyle = c.text; ctx.font = titleFont
      const lines = wrapLines(st.title || st.leader.title, titleFont, tw, 2)
      let cy = y + pad * 0.85
      drawLines(lines, left + pad, cy, tf + 4)
      cy += lines.length * (tf + 4) + 3
      ctx.fillStyle = tint
      ctx.beginPath(); ctx.arc(left + pad + 3, cy + 7, 3, 0, Math.PI * 2); ctx.fill()
      ctx.fillStyle = c.sub; ctx.font = '12px ' + state.font
      ctx.fillText(label, left + pad + 11, cy)
      if (L === 3 && !chip && !state.review) {
        ctx.fillStyle = c.faint; ctx.font = '11.5px ' + state.font
        ctx.fillText('Double-click to fan out', left + pad, y + h - pad * 0.6 - 13)
      }
      ctx.restore()
      if (chip) drawMemoryChip(chip)
      dust()
    }

    // Above an open series' first card: its name and a pill that folds it.
    function drawOpenHeads(L) {
      state.stackPills = []
      if (L === 0) return
      const c = state.colors
      for (const st of stackLayout().stacks) {
        if (!st.openHead) continue
        const head = st.openHead
        const first = state.byRef.get(head.first)
        const p = first && pos(first)
        if (!p) continue
        const [x, y] = toScreen(p[0], p[1])
        const text = '⌃ Stack ' + seriesWord(head.type, head.n)
        ctx.font = '600 11px ' + state.font
        const tw = ctx.measureText(text).width
        const bx = x, by = y - 22, bw = tw + 16, bh = 18
        ctx.fillStyle = c.card; roundRect(bx, by, bw, bh, 9); ctx.fill()
        ctx.strokeStyle = withAlpha(TYPE_TINTS[head.type] || TYPE_TINTS.other, 0.5); ctx.lineWidth = 1; ctx.stroke()
        ctx.fillStyle = c.sub; ctx.fillText(text, bx + 8, by + 3.5)
        state.stackPills.push({ key: head.key, x: bx, y: by, w: bw, h: bh })
      }
    }

    // ---- Proposals (Ask the Canvas)
    //
    // What ForeverLM proposes for a selection is drawn as ghosts until the
    // learner keeps or dismisses each one: a source as its own card, faint,
    // dashed and marked ✦; a question as a dashed sticky note; an arrow as a
    // dashed curve with its label on a ✦ pill, warm red when it contradicts.
    // A proposed source already on the plane is not drawn twice: a dashed
    // thread runs to it from the cards asked about. Ghosts are never
    // placements, a region's cards, found, undone or written to the layout
    // row; keeping one is the host's write, and no placed card ever moves to
    // make room for one.

    function ghostsShown() {
      return !!state.proposals && !state.review && !state.lens && !(state.lensFrom && state.lensT < 1)
    }
    // Ghosts settle when what is carried is let go, not while it moves.
    function ghostLayoutReady() {
      const d = state.drag
      return !(d && (d.kind === 'cards' || d.kind === 'moveRegion' || d.kind === 'resizeRegion' || d.kind === 'ghost'))
    }
    // Where a card is on the learner's plane: its place, or its slot in a
    // region laid out in rows. Not under an Idea as evidence (that comes and
    // goes with the selection), not in a lens, not on its way somewhere.
    function planePos(node) {
      const sp = stackLayout().pos.get(node.ref)
      if (sp) return sp
      const p = state.placements[node.ref]
      return p ? [p.x, p.y] : null
    }
    function planeCentre(refs) {
      let sx = 0, sy = 0, n = 0
      for (const ref of refs || []) {
        const node = state.byRef.get(ref)
        const p = node && planePos(node)
        if (!p) continue
        const [pw, ph] = sizeOf(node)
        sx += p[0] + pw / 2; sy += p[1] + ph / 2; n++
      }
      return n ? [sx / n, sy / n] : null
    }
    function viewCentre() { return toWorld(viewW() / 2, viewH() / 2) }
    // How faint Focus mode draws a card or an arrow: 1 unless something else is the point.
    // ---- The minimap
    //
    // A small canvas bottom right (when the host's `setDisplay` says so): the
    // plane's whole content fitted into it, regions as tinted rects, cards as
    // dots in their kind's colour, and the view as a stroked rect. A press or
    // a drag in it moves the camera's centre to that point. What is inside is
    // drawn once per change of layout; a frame only lays the view rect over it.
    const MM_W = 200, MM_H = 130, MM_PAD = 8
    const minimapEl = document.createElement('canvas')
    minimapEl.className = 'map-minimap'
    minimapEl.setAttribute('aria-label', 'Minimap')
    document.body.appendChild(minimapEl)
    const mmCtx = minimapEl.getContext('2d')
    const mmLayer = document.createElement('canvas')
    const mm = { dirty: true, fit: null, dpr: 0, dots: 0 }
    function drawMinimap() {
      if (!state.display.minimap || state.exporting) { mm.fit = null; return }
      const d = window.devicePixelRatio || 1
      if (mm.dpr !== d) {
        mm.dpr = d; mm.dirty = true
        for (const c of [minimapEl, mmLayer]) { c.width = Math.round(MM_W * d); c.height = Math.round(MM_H * d) }
      }
      if (state.moves.size || state.regionMoves.size || state.regionWMoves.size) mm.dirty = true
      if (mm.dirty || !mm.fit) {
        mm.dirty = false
        const b = allBounds()
        const k = Math.min((MM_W - MM_PAD * 2) / Math.max(b.w, 1), (MM_H - MM_PAD * 2) / Math.max(b.h, 1))
        mm.fit = { k, ox: (MM_W - b.w * k) / 2 - b.x * k, oy: (MM_H - b.h * k) / 2 - b.y * k }
        const g = mmLayer.getContext('2d')
        g.setTransform(d, 0, 0, d, 0, 0)
        g.clearRect(0, 0, MM_W, MM_H)
        if (!state.lens) {
          for (const r of shownRegions()) {
            const x = mm.fit.ox + r.x * k, y = mm.fit.oy + r.y * k
            g.fillStyle = withAlpha(r.color || REGION_TINTS[0], state.dark ? 0.3 : 0.2)
            g.fillRect(x, y, Math.max(2, r.w * k), Math.max(2, r.h * k))
            g.strokeStyle = withAlpha(r.color || REGION_TINTS[0], 0.55); g.lineWidth = 1
            g.strokeRect(x + 0.5, y + 0.5, Math.max(2, r.w * k) - 1, Math.max(2, r.h * k) - 1)
          }
        }
        let dots = 0
        for (const ref of state.lens ? Object.keys(state.lens.positions) : Object.keys(state.placements)) {
          const node = state.byRef.get(ref), p = node && pos(node)
          if (!p) continue
          const [w, h] = sizeOf(node)
          g.fillStyle = withAlpha(TYPE_TINTS[node.type] || TYPE_TINTS[node.kind] || TYPE_TINTS.other, 0.85)
          g.fillRect(mm.fit.ox + p[0] * k, mm.fit.oy + p[1] * k, Math.max(1.6, w * k), Math.max(1.6, h * k))
          dots++
        }
        mm.dots = dots
      }
      mmCtx.setTransform(d, 0, 0, d, 0, 0)
      mmCtx.clearRect(0, 0, MM_W, MM_H)
      mmCtx.drawImage(mmLayer, 0, 0, MM_W, MM_H)
      // The view.
      const [x0, y0] = toWorld(0, 0), [x1, y1] = toWorld(viewW(), viewH())
      const { k, ox, oy } = mm.fit
      const vx = clamp(ox + x0 * k, -4, MM_W + 4), vy = clamp(oy + y0 * k, -4, MM_H + 4)
      const vw = clamp(ox + x1 * k, -4, MM_W + 4) - vx, vh = clamp(oy + y1 * k, -4, MM_H + 4) - vy
      mmCtx.fillStyle = withAlpha(state.colors.select, 0.08)
      mmCtx.fillRect(vx, vy, vw, vh)
      mmCtx.strokeStyle = state.colors.select; mmCtx.lineWidth = 1.5
      mmCtx.strokeRect(vx, vy, vw, vh)
    }
    // The camera's middle goes to a point of the minimap.
    function minimapTo(e, fly) {
      if (!mm.fit) return
      const r = minimapEl.getBoundingClientRect()
      const wx = (e.clientX - r.left - mm.fit.ox) / mm.fit.k, wy = (e.clientY - r.top - mm.fit.oy) / mm.fit.k
      const ox = viewW() / 2 - wx * state.scale, oy = viewH() / 2 - wy * state.scale
      if (fly) { flyCamera(state.scale, ox, oy, 200); return }
      stopCamera()
      state.ox = ox; state.oy = oy
      redraw(); scheduleViewReport()
    }
    let mmDrag = false
    minimapEl.addEventListener('pointerdown', (e) => {
      e.preventDefault()
      if (state.editor) closeEditor(true)
      try { minimapEl.setPointerCapture(e.pointerId) } catch (err) { /* the harness's synthetic events */ }
      mmDrag = true
      minimapTo(e, true)
    })
    minimapEl.addEventListener('pointermove', (e) => { if (mmDrag) minimapTo(e, false) })
    minimapEl.addEventListener('pointerup', () => { mmDrag = false })
    minimapEl.addEventListener('pointercancel', () => { mmDrag = false })
    minimapEl.addEventListener('wheel', onWheel, { passive: false })

    // ---- Focus mode
    //
    // With the switch on (the host's `setDisplay`), everything but what is
    // selected and what its arrows reach draws at 15%: every card not selected
    // and not joined by an arrow (either way) or an evidence link to a selected
    // card, and every arrow or thread not touching the selection. Regions keep
    // their tint. With one card selected the arrow keys then follow the arrows
    // (→ the first target of its outgoing ones, clockwise from the right; ← the
    // first source of its incoming ones) and, in a mind map, the tree (↑ ↓).
    const FOCUS_DIM = 0.15
    function focusSet() {
      if (!state.display.focus || state.lens || state.exporting) return null
      const sel = state.selection
      const key = state.focusCache
      if (key && key.sel === sel && key.size === sel.size) return key.value
      let value = null
      const chosen = new Set(sel)
      if (state.selectedEdge && state.edges[state.selectedEdge]) {
        const e = state.edges[state.selectedEdge]
        chosen.add(e.from); chosen.add(e.to)
      }
      if (chosen.size) {
        const refs = new Set(chosen), touching = new Set()
        for (const e of Object.values(state.edges)) {
          const a = chosen.has(e.from), b = chosen.has(e.to)
          if (!a && !b) continue
          touching.add(e.id)
          refs.add(a ? e.to : e.from)
        }
        for (const [ideaRef, list] of state.evidence) {
          if (chosen.has(ideaRef)) for (const r of list) refs.add(r)
          else for (const r of list) if (chosen.has(r)) { refs.add(ideaRef); break }
        }
        value = { refs, touching }
      }
      state.focusCache = { sel, size: sel.size, value }
      return value
    }
    // How faint a card (a node) or an arrow (an edge) draws.
    function focusDim(x) {
      const set = focusSet()
      if (!set) return 1
      if (x.id != null && x.from != null) return set.touching.has(x.id) ? 1 : FOCUS_DIM
      const st = stackOf(x)
      return (st ? st.refs.some(r => set.refs.has(r)) : set.refs.has(x.ref)) ? 1 : FOCUS_DIM
    }
    // The camera comes to a card, centred at the scale it has.
    function flyToCard(node) {
      const p = pos(node)
      if (!p) return
      const [w, h] = sizeOf(node)
      const s = state.scale
      flyCamera(s, viewW() / 2 - (p[0] + w / 2) * s, viewH() / 2 - (p[1] + h / 2) * s, 320)
    }
    // An angle clockwise from `from` (radians) in [0, 2π).
    function clockwise(dx, dy, from) {
      let a = Math.atan2(dy, dx) - from
      while (a < 0) a += Math.PI * 2
      return a % (Math.PI * 2)
    }
    function focusWalk(key) {
      if (!state.display.focus || state.lens || state.selection.size !== 1) return false
      const ref = [...state.selection][0]
      const node = state.byRef.get(ref), p = node && pos(node)
      if (!p) return false
      const [w, h] = sizeOf(node)
      const mid = [p[0] + w / 2, p[1] + h / 2]
      let target = null
      if (key === 'ArrowRight' || key === 'ArrowLeft') {
        const out = key === 'ArrowRight'
        let best = Infinity
        for (const e of Object.values(state.edges)) {
          const other = out ? (e.from === ref ? e.to : null) : (e.to === ref ? e.from : null)
          const on = other && state.byRef.get(other), op = on && pos(on)
          if (!op) continue
          const [ow, oh] = sizeOf(on)
          const a = clockwise(op[0] + ow / 2 - mid[0], op[1] + oh / 2 - mid[1], out ? 0 : Math.PI)
          if (a < best) { best = a; target = on }
        }
      } else if (treeRegionOf(ref)) {
        const { kids, parent } = treeIndex()
        const up = key === 'ArrowUp'
        const parentRef = parent.get(ref)
        const sibs = (parentRef ? kids.get(parentRef) || [] : [...(stackLayout().members.get(stackLayout().innermost.get(ref)) || [])].filter(r => !parent.has(r)))
          .map(r => state.byRef.get(r)).filter(n => n && pos(n))
          .sort((a, b) => pos(a)[1] - pos(b)[1])
        const i = sibs.findIndex(n => n.ref === ref)
        target = sibs[i + (up ? -1 : 1)] || null
      } else return false
      if (!target) return true
      selectRegion(null); selectEdge(null)
      setSelection([target.ref])
      flyToCard(target)
      return true
    }

    // What a ghost may not overlap, in cells for quick looks: every card on
    // the plane, every region with room for its name above it, and under each
    // placed Idea the block its evidence hangs in when shown.
    function ghostObstacles() {
      const CELL = 540
      const cells = new Map()
      const span = (r) => [Math.floor(r.x / CELL), Math.floor((r.x + r.w) / CELL), Math.floor(r.y / CELL), Math.floor((r.y + r.h) / CELL)]
      const add = (r) => {
        const [i0, i1, j0, j1] = span(r)
        for (let i = i0; i <= i1; i++) {
          for (let j = j0; j <= j1; j++) {
            const k = i + ',' + j
            const list = cells.get(k)
            if (list) list.push(r); else cells.set(k, [r])
          }
        }
      }
      const hits = (r) => {
        const [i0, i1, j0, j1] = span(r)
        for (let i = i0; i <= i1; i++) {
          for (let j = j0; j <= j1; j++) {
            const list = cells.get(i + ',' + j)
            if (!list) continue
            for (const o of list) if (r.x < o.x + o.w && o.x < r.x + r.w && r.y < o.y + o.h && o.y < r.y + r.h) return true
          }
        }
        return false
      }
      for (const node of state.nodes) {
        const p = planePos(node)
        if (p) { const [pw, ph] = sizeOf(node); add({ x: p[0], y: p[1], w: pw, h: ph }) }
      }
      for (const r of shownRegions()) add({ x: r.x - GAP, y: r.y - GAP - 100, w: r.w + GAP * 2, h: r.h + GAP * 2 + 100 })
      for (const [ideaRef, refs] of state.evidence) {
        const idea = placedBox(ideaRef)
        if (!idea) continue
        const loose = refs.filter(ref => { const n = state.byRef.get(ref); return n && !planePos(n) }).length
        if (!loose) continue
        const cols = Math.min(EV_COLS, loose), rows = Math.ceil(loose / cols)
        const rowW = cols * (EV_W + EV_GAP) - EV_GAP
        add({ x: idea.x + idea.w / 2 - rowW / 2, y: idea.y + idea.h, w: rowW, h: 26 + rows * (EV_H + EV_GAP) })
      }
      return { add, hits }
    }

    // The slots around a point, nearest first: a card's size and the usual
    // gap, in rows tall enough for the ✦ line under a ghost that has one
    // (`room`), the first row below a card a gap under it. Ties go below
    // before above and right before left. Worked out once per row height.
    const slotOrders = new Map()
    function slotOrder(room) {
      let list = slotOrders.get(room)
      if (list) return list
      list = []
      const pitchY = CARD_H + GAP + room
      for (let j = -40; j <= 40; j++) {
        for (let i = -24; i <= 24; i++) {
          const dx = i * (CARD_W + GAP), dy = j * pitchY - (j > 0 ? room : 0)
          list.push({ dx, dy, d: Math.hypot(dx, dy), i, j })
        }
      }
      list.sort((a, b) => a.d - b.d || b.j - a.j || b.i - a.i)
      slotOrders.set(room, list)
      return list
    }
    function ghostFootprint(x, y, room) {
      return { x: x - GHOST_MARGIN, y: y - GHOST_MARGIN, w: CARD_W + GHOST_MARGIN * 2, h: CARD_H + room + GHOST_MARGIN * 2 }
    }
    function freeSlot(c, room, grid) {
      const x0 = c[0] - CARD_W / 2, y0 = c[1] - CARD_H / 2
      for (const o of slotOrder(room)) {
        const x = round(x0 + o.dx), y = round(y0 + o.dy)
        if (!grid.hits(ghostFootprint(x, y, room))) return { x, y }
      }
      return null
    }

    // Each proposed source and question takes the nearest free slot to the
    // middle of the cards it answers (else of the cards asked about), in the
    // order proposed, so the same plane and proposals give the same slots.
    // Laid out again when the plane changes, a ghost stays where it is
    // unless something now overlaps it, and one being kept stays put.
    function layoutGhosts(force) {
      state.ghostsDirty = false
      const set = state.proposals
      const before = state.ghosts
      const next = new Map()
      if (set && state.gotContent && state.gotLayout) {
        const grid = ghostObstacles()
        const asked = planeCentre(set.anchor)
        // A Mind Map's or Question Map's questions are laid out together, as a tree.
        const tree = set.plan && set.plan.tree ? set.plan : null
        if (tree) layoutGhostTree(set, tree, grid, asked, next)
        // One row height for the whole set, so its ghosts line up in rows.
        const room = set.proposals.some(p => p && (p.kind === 'source' || p.kind === 'question') && p.why) ? WHY_ROOM : 0
        for (const p of set.proposals) {
          if (!p || p.id == null) continue
          const id = String(p.id)
          const gone = state.ghostGone.get(id)
          if (gone && gone.kind === 'dismissed') continue
          if (tree && p.kind === 'question') continue
          if (p.kind === 'edge') {
            if (p.from && p.to) next.set(id, { id, p, kind: 'edge' })
            continue
          }
          let node
          if (p.kind === 'source') {
            node = p.ref ? state.byRef.get(p.ref) : null
            if (!node) continue
            if (planePos(node)) { next.set(id, { id, p, kind: 'thread', node }); continue }
          } else if (p.kind === 'question') node = { ref: 'proposal:' + id, kind: 'idea', title: String(p.text || '') }
          else continue
          const old = before.get(id)
          let spot
          if (old && old.kind === 'card' && (gone || !grid.hits(ghostFootprint(old.x, old.y, room)))) spot = { x: old.x, y: old.y }
          else spot = freeSlot(planeCentre(p.near) || asked || viewCentre(), room, grid)
          if (!spot) continue
          grid.add(ghostFootprint(spot.x, spot.y, room))
          next.set(id, { id, p, kind: 'card', node, x: spot.x, y: spot.y, room })
        }
      }
      state.ghosts = next
      if (state.ghostSelected && !next.has(state.ghostSelected)) state.ghostSelected = null
      if (state.ghostHover && !next.has(state.ghostHover)) { state.ghostHover = null; state.ghostPart = null }
      postGhostLayout(force)
    }
    // ---- Ghost trees
    //
    // A Mind Map or Question Map (a set whose `plan.tree` is true) is proposed
    // as a tidy tree with the look and sizes of a placed mind map's nodes
    // (`treeNodeSize`), in the order proposed, not in free slots. With
    // `plan.rootRef` a placed card, the tree grows from it: its children's
    // column 60 points right of the card, the block centred on the card's
    // middle, and the card itself never moves. Without one, the ghost root and
    // its tree go in the free spot nearest the asked cards that holds the
    // tree's whole box. The branches are dashed in ForeverLM's colour. The
    // tree is laid out once and kept as it is (a ghost kept or dismissed
    // leaves a gap, not a reflow), until the card it grows from moves or
    // something lands on the box.
    // The ghost tree's tint after `base`'s, for its i-th branch.
    function nextTint(base, i) { return REGION_TINTS[(REGION_TINTS.indexOf(base) + 1 + i) % REGION_TINTS.length] }
    // The spots for a box about a point, nearest first (80 apart), the right and below before the left and above.
    let boxSpots = null
    function freeBoxSpot(c, w, h, grid) {
      if (!boxSpots) {
        boxSpots = []
        for (let j = -60; j <= 60; j++) for (let i = -60; i <= 60; i++) boxSpots.push({ dx: i * 80, dy: j * 80, d: Math.hypot(i, j) })
        boxSpots.sort((a, b) => a.d - b.d || b.dy - a.dy || b.dx - a.dx)
      }
      for (const o of boxSpots) {
        const x = round(c[0] - w / 2 + o.dx), y = round(c[1] - h / 2 + o.dy)
        if (!grid.hits({ x: x - GHOST_MARGIN, y: y - GHOST_MARGIN, w: w + GHOST_MARGIN * 2, h: h + GHOST_MARGIN * 2 })) return { x, y }
      }
      return null
    }
    function layoutGhostTree(set, plan, grid, asked, out) {
      const nodes = new Map()
      for (const p of set.proposals) {
        if (p && p.id != null && p.kind === 'question') nodes.set(String(p.id), { id: String(p.id), p, kids: [], root: false, tint: null })
      }
      const parentOf = new Map((plan.arrows || []).map(a => [String(a.to), String(a.from)]))
      const rootBox = plan.rootRef && state.byRef.get(plan.rootRef) ? endRect(plan.rootRef) : null
      const rootRef = rootBox ? plan.rootRef : null
      let memory = state.ghostTree
      if (!memory || memory.setId !== set.id) memory = state.ghostTree = { setId: set.id, key: null, rects: new Map(), parents: parentOf, dismissed: new Set(), free: null, rootRef }
      memory.rootRef = rootRef
      const gone = (id) => { const g = state.ghostGone.get(id); return !!g && g.kind === 'dismissed' }
      // A proposal kept leaves the set but its Idea stands where its ghost was.
      const kept = (id) => !nodes.has(id) && memory.rects.has(id) && !memory.dismissed.has(id)
      // Each proposal's parent: the branch that leads to it, by way of any
      // proposal that is gone (dismissed, or not there: `plan.arrows` still name
      // it) to the one before. A branch that ends at a proposal kept leaves the
      // ghost hanging where it was; one that ends nowhere makes it a root of its own.
      const tops = [], underRoot = []
      for (const n of nodes.values()) {
        if (gone(n.id)) continue
        let up = parentOf.get(n.id)
        for (let hops = 0; up != null && up !== rootRef && !(nodes.has(up) && !gone(up)) && !kept(up) && hops < 64; hops++) up = parentOf.get(up)
        if (up != null && up === rootRef) underRoot.push(n)
        else if (up != null && nodes.has(up) && !gone(up)) nodes.get(up).kids.push(n)
        else { n.root = !(up != null && kept(up)); tops.push(n) }
      }
      const mind = rootRef ? mindInfo(state.byRef.get(rootRef)) : null
      // The region's tint the branches' colours follow: the root card's, else the next region's.
      const base = mind ? (state.regions[mind.regionID].color || REGION_TINTS[0]) : REGION_TINTS[Object.keys(state.regions).length % REGION_TINTS.length]
      const measure = (n) => {
        const size = treeNodeSize(String(n.p.text || ''), n.root ? 'root' : n.kids.length ? 'branch' : 'leaf')
        n.w = size.w; n.h = size.h
        let block = 0
        for (const k of n.kids) block += measure(k) + (block ? TREE_GAP : 0)
        n.block = block; n.total = Math.max(n.h, block)
        return n.total
      }
      const paint = (n, tint) => { n.tint = tint; for (const k of n.kids) paint(k, tint) }
      let right = 0
      const put = (n, x, top) => {
        n.x = x; n.y = top + (n.total - n.h) / 2
        right = Math.max(right, x + n.w)
        let y = top + (n.total - n.block) / 2
        for (const k of n.kids) { put(k, x + n.w + TREE_COL, y); y += k.total + TREE_GAP }
      }
      const shift = (n, dx, dy) => { n.x += dx; n.y += dy; for (const k of n.kids) shift(k, dx, dy) }
      const key = rootBox ? 'root|' + [rootBox.x, rootBox.y, rootBox.w, rootBox.h].map(round).join('|') : 'free'
      // Still standing where it was laid out, unless something has landed on its box.
      let standing = memory.key === key && [...nodes.values()].every(n => gone(n.id) || memory.rects.has(n.id))
      const margin = (r) => ({ x: r.x - GHOST_MARGIN, y: r.y - GHOST_MARGIN, w: r.w + GHOST_MARGIN * 2, h: r.h + GHOST_MARGIN * 2 })
      if (standing && memory.free && grid.hits(margin(memory.free))) standing = false
      // What hangs from a placed card takes the next tints after its region's (or its branch's); the others are trees of their own.
      if (mind && mind.role !== 'root') for (const n of underRoot) paint(n, nodeTint(state.byRef.get(rootRef), mind))
      else underRoot.forEach((n, i) => paint(n, nextTint(base, i)))
      let total = 0
      for (const n of underRoot) total += measure(n) + (total ? TREE_GAP : 0)
      for (const n of tops) {
        measure(n)
        if (n.root) { n.tint = base; n.kids.forEach((k, i) => paint(k, nextTint(base, i))) }
        else { const was = memory.rects.get(n.id); paint(n, was && was.tint || nextTint(base, 0)) }
      }
      if (!standing) {
        // The children's column, the block level with the card's middle.
        let y = underRoot.length ? rootBox.y + rootBox.h / 2 - total / 2 : 0
        for (const n of underRoot) { put(n, rootBox.x + rootBox.w + TREE_COL, y); y += n.total + TREE_GAP }
        // The roots stacked, the whole box put in the free spot nearest the asked cards.
        memory.free = null
        if (tops.length) {
          right = 0
          let top = 0
          for (const n of tops) { put(n, 0, top); top += n.total + TREE_ROOT_GAP }
          const box = { w: right, h: top - TREE_ROOT_GAP }
          const c = asked || viewCentre()
          const at = freeBoxSpot(c, box.w, box.h, grid) || { x: round(c[0] - box.w / 2), y: round(c[1] - box.h / 2) }
          for (const n of tops) shift(n, at.x, at.y)
          memory.free = { x: at.x, y: at.y, w: box.w, h: box.h }
        }
      }
      if (memory.free) grid.add(margin(memory.free))
      memory.key = key
      // What was laid out stays where it was while it stands; a ghost gone is
      // remembered where it was, for the branches that hung from it.
      const rects = new Map()
      for (const n of nodes.values()) {
        const was = standing && memory.rects.get(n.id)
        if (gone(n.id) || (!was && n.x == null)) continue
        const r = { x: was ? was.x : round(n.x), y: was ? was.y : round(n.y), w: n.w, h: n.h, tint: n.tint }
        rects.set(n.id, r)
        const parent = parentOf.get(n.id)
        out.set(n.id, {
          id: n.id, p: n.p, kind: 'card', x: r.x, y: r.y, room: 0,
          node: { ref: 'proposal:' + n.id, kind: 'idea', type: 'idea', title: String(n.p.text || ''), sub: n.p.note ? String(n.p.note) : 'Idea', detail: [], shore: '' },
          tree: { role: n.root ? 'root' : n.kids.length ? 'branch' : 'leaf', w: n.w, h: n.h, tint: n.tint, parent: parent == null ? null : parent },
        })
      }
      for (const [id, r] of memory.rects) if (!rects.has(id)) rects.set(id, r)
      memory.rects = rects
    }
    // The spot a card ghost is drawn at: where it is carried while it is, else its slot.
    function ghostSpot(g) {
      const d = state.drag
      return d && d.kind === 'ghost' && d.id === g.id && d.moved ? [d.x, d.y] : [g.x, g.y]
    }
    // Where the branch to a ghost in a tree starts: the ghost before it (or the
    // placed card the tree grows from), else, when that one has been kept, where
    // it was (a ghost dismissed is skipped: its own parent takes its place).
    function ghostBranchFrom(g) {
      const mem = state.ghostTree
      let up = g.tree.parent
      for (let hops = 0; up != null && hops < 64; hops++) {
        if (mem && up === mem.rootRef) return endRect(up)
        const live = state.ghosts.get(up)
        if (live && live.tree) { const [x, y] = ghostSpot(live); return { x, y, w: live.tree.w, h: live.tree.h } }
        const memo = mem && mem.rects.get(up)
        if (memo && !mem.dismissed.has(up)) return memo
        up = mem ? mem.parents.get(up) : null
      }
      return null
    }

    // The host keeps where each ghost is drawn, so Keep All places every one
    // there.
    function postGhostLayout(force) {
      const positions = {}
      for (const g of state.ghosts.values()) if (g.kind === 'card') positions[g.p.id] = { x: g.x, y: g.y }
      const key = JSON.stringify(positions)
      if (!force && key === state.ghostPosted) return
      state.ghostPosted = key
      host.post('proposalLayout', { positions })
    }

    // A proposed arrow's curve and a thread to a proposed source run under
    // the cards, as the learner's own arrows do; their pills, the ghost cards
    // and the buttons are drawn over everything (drawGhosts).
    function drawGhostLines(L) {
      if (!ghostsShown() || !state.ghosts.size || L === 0) return
      for (const g of state.ghosts.values()) {
        if (g.kind === 'edge') drawGhostEdge(g, L, false)
        else if (g.kind === 'thread') drawGhostThread(g, L, false)
        else if (g.kind === 'card' && g.tree) drawGhostBranch(g)
      }
    }
    // A proposed branch: a dashed S-curve in ForeverLM's colour, from the right
    // middle of the ghost (or card) before it to the left middle of this one.
    function drawGhostBranch(g) {
      const from = ghostBranchFrom(g)
      if (!from) return
      const [bx, by] = ghostSpot(g)
      const p0 = [from.x + from.w, from.y + from.h / 2], p3 = [bx, by + g.tree.h / 2]
      const k = Math.max(24, Math.abs(p3[0] - p0[0]) * 0.5)
      const [a, b, c, d] = [p0, [p0[0] + k, p0[1]], [p3[0] - k, p3[1]], p3].map(pt => toScreen(pt[0], pt[1]))
      const keeping = state.ghostGone.has(g.id)
      ctx.save()
      ctx.strokeStyle = state.colors.ai; ctx.lineWidth = state.ghostSelected === g.id || state.ghostHover === g.id ? 2.4 : 1.8; ctx.lineCap = 'round'
      if (!keeping) { ctx.globalAlpha *= 0.9; ctx.setLineDash([6, 5]) }
      ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.bezierCurveTo(b[0], b[1], c[0], c[1], d[0], d[1]); ctx.stroke()
      ctx.restore()
    }
    function drawGhosts(L, W, H) {
      state.ghostHits = []
      state.ghostButtons = []
      if (!ghostsShown() || !state.ghosts.size) return
      for (const g of state.ghosts.values()) {
        if (g.kind === 'edge') drawGhostEdge(g, L, true)
        else if (g.kind === 'thread') drawGhostThread(g, L, true)
      }
      for (const g of state.ghosts.values()) if (g.kind === 'card') drawGhostCard(g, L, W, H)
      // The ✓ and × of the ghost picked and of the one under the pointer.
      if (state.drag && state.drag.kind === 'ghost' && state.drag.moved) return
      for (const id of new Set([state.ghostSelected, state.ghostHover])) {
        const hit = id && state.ghostHits.find(h => h.id === id)
        if (hit) drawGhostButtons(id, hit.anchor)
      }
    }

    function drawGhostCard(g, L, W, H) {
      const c = state.colors
      const s = state.scale
      const d = state.drag && state.drag.kind === 'ghost' && state.drag.id === g.id && state.drag.moved ? state.drag : null
      const gx = d ? d.x : g.x, gy = d ? d.y : g.y
      const [x, y] = toScreen(gx, gy)
      const w = (g.tree ? g.tree.w : CARD_W) * s, h = (g.tree ? g.tree.h : CARD_H) * s
      const keeping = state.ghostGone.has(g.id)
      const whyH = L >= 2 && g.p.why && !keeping && !d ? g.room * s : 0
      if (x > W + 40 || y > H + 40 || x + w < -40 || y + h + whyH < -40) return
      const radius = Math.max(2, (g.p.kind === 'question' ? 4 : 12) * s)
      ctx.save()
      ctx.globalAlpha = keeping ? 1 : d ? 0.92 : GHOST_ALPHA
      drawNode(g.node, L, W, H, false, { x: gx, y: gy, lifted: !!d, tree: g.tree })
      ctx.restore()
      if (keeping) return
      const picked = state.ghostSelected === g.id
      // A tree's ghosts are outlined dashed already: the ring shows when one is picked or under the pointer.
      if (!g.tree || picked || state.ghostHover === g.id) {
        ctx.strokeStyle = c.ai
        ctx.lineWidth = picked ? 2 : state.ghostHover === g.id ? 1.8 : 1.4
        if (!picked) ctx.setLineDash([5, 4])
        roundRect(x - 3, y - 3, w + 6, h + 6, radius + 3); ctx.stroke(); ctx.setLineDash([])
      }
      if (L === 0) return
      // ForeverLM's mark on its corner (on a tree's small nodes, over the corner, clear of the words).
      const br = g.tree ? 6.5 : L >= 2 ? 8 : 6.5
      const mx = g.tree ? x : x + 4, my = g.tree ? y : y + 4
      ctx.fillStyle = c.ai
      ctx.beginPath(); ctx.arc(mx, my, br, 0, Math.PI * 2); ctx.fill()
      ctx.fillStyle = '#ffffff'; ctx.font = '600 ' + (L >= 2 && !g.tree ? 10 : 8.5) + 'px ' + state.font
      ctx.textBaseline = 'middle'
      ctx.fillText('✦', mx - ctx.measureText('✦').width / 2, my + 0.5)
      ctx.textBaseline = 'top'
      // Why, in ForeverLM's voice, in the room kept under the ghost.
      const lines = Math.min(2, Math.floor((whyH - 4) / 16))
      if (lines > 0) {
        const font = 'italic 12px ' + state.font
        ctx.font = font; ctx.fillStyle = c.ai
        drawLines(wrapLines('✦ ' + g.p.why, font, w, lines), x, y + h + 6, 16)
      }
      state.ghostHits.push({ id: g.id, rect: { x: x - 3, y: y - 3, w: w + 6, h: h + 6 }, anchor: [x + w - 10, y - 2] })
    }

    // Keep (✓) and Dismiss (×), side by side, the × at `a`.
    function drawGhostButtons(id, a) {
      const c = state.colors
      const r = 10
      for (const [part, cx] of [['keep', a[0] - 2 * r - 5], ['dismiss', a[0]]]) {
        const cy = a[1]
        const hot = state.ghostHover === id && state.ghostPart === part
        const tone = part === 'keep' ? c.memSolid : c.contra
        ctx.save()
        ctx.shadowColor = c.shadow; ctx.shadowBlur = 6; ctx.shadowOffsetY = 1
        ctx.fillStyle = c.card
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.fill()
        ctx.restore()
        if (hot) { ctx.fillStyle = withAlpha(tone, 0.16); ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.fill() }
        ctx.strokeStyle = hot ? withAlpha(tone, 0.8) : withAlpha(c.text, 0.14); ctx.lineWidth = 1
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
        ctx.strokeStyle = part === 'keep' || hot ? tone : c.sub
        ctx.lineWidth = 1.8; ctx.lineCap = 'round'; ctx.lineJoin = 'round'
        ctx.beginPath()
        if (part === 'keep') { ctx.moveTo(cx - 4, cy + 0.2); ctx.lineTo(cx - 1.2, cy + 3); ctx.lineTo(cx + 4.2, cy - 3.2) }
        else { ctx.moveTo(cx - 3.2, cy - 3.2); ctx.lineTo(cx + 3.2, cy + 3.2); ctx.moveTo(cx + 3.2, cy - 3.2); ctx.lineTo(cx - 3.2, cy + 3.2) }
        ctx.stroke()
        ctx.lineCap = 'butt'; ctx.lineJoin = 'miter'
        state.ghostButtons.push({ id, part, cx, cy, r: r + 3 })
      }
    }

    function ghostPill(text, cx, cy, tone, dashed, strong) {
      const c = state.colors
      ctx.font = '500 11.5px ' + state.font
      const tw = ctx.measureText(text).width
      const box = { x: cx - tw / 2 - 9, y: cy - 11, w: tw + 18, h: 22 }
      ctx.save()
      ctx.shadowColor = c.shadow; ctx.shadowBlur = 6; ctx.shadowOffsetY = 1
      ctx.fillStyle = c.card
      roundRect(box.x, box.y, box.w, box.h, 11); ctx.fill()
      ctx.restore()
      ctx.strokeStyle = withAlpha(tone, strong ? 0.95 : 0.6); ctx.lineWidth = strong ? 1.5 : 1
      if (dashed) ctx.setLineDash([3, 3])
      roundRect(box.x, box.y, box.w, box.h, 11); ctx.stroke(); ctx.setLineDash([])
      ctx.fillStyle = tone
      ctx.fillText(text, cx - tw / 2, cy - 6.5)
      return box
    }

    // Where an arrow's end is drawn: a card on the plane, or a source the
    // same proposals put down as a ghost.
    function ghostEnd(ref) {
      const node = state.byRef.get(ref)
      const p = node && pos(node)
      if (p) return p
      for (const g of state.ghosts.values()) if (g.kind === 'card' && g.p.ref === ref) return [g.x, g.y]
      return null
    }
    // Its curve and arrowhead under the cards; its ✦ pill (`top`) over them.
    function drawGhostEdge(g, L, top) {
      if (L === 0) return
      const a = ghostEnd(g.p.from), b = ghostEnd(g.p.to)
      if (!a || !b || (a[0] === b[0] && a[1] === b[1])) return
      const c = state.colors
      const keeping = state.ghostGone.has(g.id)
      const strong = state.ghostSelected === g.id || state.ghostHover === g.id
      const tone = g.p.relation === 'contradicts' ? c.contra : c.select
      const [p, m, q] = curveBetween(a, b).map(pt => toScreen(pt[0], pt[1]))
      if (!top) {
        ctx.save()
        ctx.strokeStyle = tone; ctx.fillStyle = tone
        ctx.lineWidth = strong ? 2.4 : 1.8; ctx.lineCap = 'round'
        if (!keeping) { ctx.globalAlpha *= 0.9; ctx.setLineDash([6, 5]) }
        ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.quadraticCurveTo(m[0], m[1], q[0], q[1]); ctx.stroke()
        ctx.setLineDash([])
        const ang = Math.atan2(q[1] - m[1], q[0] - m[0])
        ctx.beginPath(); ctx.moveTo(q[0], q[1])
        ctx.lineTo(q[0] - 10 * Math.cos(ang - 0.42), q[1] - 10 * Math.sin(ang - 0.42))
        ctx.lineTo(q[0] - 10 * Math.cos(ang + 0.42), q[1] - 10 * Math.sin(ang + 0.42))
        ctx.closePath(); ctx.fill()
        ctx.restore()
        return
      }
      const mid = curvePoint(p, m, q, 0.5)
      const words = String(g.p.label || g.p.relation || '').replace(/_/g, ' ').trim()
      const box = ghostPill(L >= 2 && words ? '✦ ' + words : '✦', mid[0], mid[1], tone, !keeping, strong)
      if (keeping) return
      const curve = []
      for (let i = 0; i <= 16; i++) curve.push(curvePoint(p, m, q, i / 16))
      state.ghostHits.push({ id: g.id, rect: box, curve, anchor: [box.x + box.w + 39, box.y + box.h / 2] })
    }
    // A proposed source already on the plane: ringed where it is, and a
    // dashed thread to it from the cards asked about (under the cards), with
    // why on a ✦ pill (`top`, over them).
    function drawGhostThread(g, L, top) {
      if (L === 0 || state.ghostGone.has(g.id)) return
      const target = pos(g.node)
      if (!target) return
      const c = state.colors
      const s = state.scale
      const [tw, th] = sizeOf(g.node)
      const tc = [target[0] + tw / 2, target[1] + th / 2]
      const strong = state.ghostSelected === g.id || state.ghostHover === g.id
      const [x, y] = toScreen(target[0], target[1])
      const asked = worldBounds(state.proposals.anchor || [])
      let line = null
      if (asked) {
        const from = [asked.x + asked.w / 2, asked.y + asked.h / 2]
        const start = clipToRect(from, tc, asked.w / 2 + 8, asked.h / 2 + 8)
        const end = clipToRect(tc, from, tw / 2 + 10, th / 2 + 10)
        const [ax, ay] = toScreen(start[0], start[1]), [bx, by] = toScreen(end[0], end[1])
        if (Math.hypot(bx - ax, by - ay) > 40) line = [ax, ay, bx, by]
      }
      if (!top) {
        ctx.save()
        ctx.strokeStyle = c.ai; ctx.lineWidth = strong ? 2 : 1.4; ctx.setLineDash([5, 4])
        // Ringed where it is, unless its notebook's frame has folded it away.
        if (folded(g.node) < 0.5) { roundRect(x - 5, y - 5, tw * s + 10, th * s + 10, Math.max(2, 12 * s) + 5); ctx.stroke() }
        if (line) {
          ctx.setLineDash([2, 6]); ctx.lineCap = 'round'; ctx.lineWidth = 1.8
          ctx.beginPath(); ctx.moveTo(line[0], line[1]); ctx.lineTo(line[2], line[3]); ctx.stroke()
        }
        ctx.restore()
        return
      }
      const mid = line ? [(line[0] + line[2]) / 2, (line[1] + line[3]) / 2] : [x + tw * s / 2, y - 24]
      const words = L >= 2 && g.p.why ? wrapLines('✦ ' + g.p.why, '500 11.5px ' + state.font, 260, 1)[0] : '✦'
      const box = ghostPill(words, mid[0], mid[1], c.ai, true, strong)
      state.ghostHits.push({ id: g.id, rect: box, anchor: [box.x + box.w + 39, box.y + box.h / 2] })
    }

    // The ghost (or one of its buttons) under a point, the top one first.
    function hitGhost(px, py) {
      if (!ghostsShown() || level() === 0) return null
      for (let i = state.ghostButtons.length - 1; i >= 0; i--) {
        const b = state.ghostButtons[i]
        if (Math.hypot(px - b.cx, py - b.cy) <= b.r) return { id: b.id, part: b.part }
      }
      for (let i = state.ghostHits.length - 1; i >= 0; i--) {
        const h = state.ghostHits[i]
        const r = h.rect
        if (px >= r.x && px <= r.x + r.w && py >= r.y && py <= r.y + r.h) return { id: h.id, part: 'body' }
        if (!h.curve) continue
        for (let k = 1; k < h.curve.length; k++) {
          const a = h.curve[k - 1], b = h.curve[k]
          if (distToSegment(px, py, a[0], a[1], b[0], b[1]) < 6) return { id: h.id, part: 'body' }
        }
      }
      return null
    }
    // One thing is picked at a time, so ⌫ only ever dismisses the ghost.
    function pickGhost(id) {
      if (state.selection.size) setSelection([])
      if (state.selectedRegion) selectRegion(null)
      if (state.selectedEdge) selectEdge(null)
      state.ghostSelected = id
      redraw()
    }
    // Keeping is the host's write (a placement, an arrow, an Idea). Until
    // its next set takes the ghost back it is drawn as kept, where it was
    // let go.
    function keepGhost(id, at) {
      const g = state.ghosts.get(id)
      if (!g || state.ghostGone.has(id)) return
      const message = { id: g.p.id }
      if (g.kind === 'card') {
        if (at) { g.x = round(at.x); g.y = round(at.y) }
        message.x = g.x; message.y = g.y
        const memo = g.tree && state.ghostTree && state.ghostTree.rects.get(id)
        if (memo) { memo.x = g.x; memo.y = g.y }
      } else if (g.kind === 'thread') {
        const p = planePos(g.node)
        if (p) { message.x = round(p[0]); message.y = round(p[1]) }
      }
      state.ghostGone.set(id, { kind: 'keeping', t: performance.now() })
      if (state.ghostSelected === id) state.ghostSelected = null
      if (state.ghostHover === id) { state.ghostHover = null; state.ghostPart = null }
      host.post('proposalKeep', message)
      expireKept()
      invalidate()
    }
    function dismissGhost(id) {
      const g = state.ghosts.get(id)
      if (!g || state.ghostGone.has(id)) return
      state.ghostGone.set(id, { kind: 'dismissed' })
      if (g.tree && state.ghostTree) state.ghostTree.dismissed.add(id)
      if (state.ghostSelected === id) state.ghostSelected = null
      if (state.ghostHover === id) { state.ghostHover = null; state.ghostPart = null }
      host.post('proposalDismiss', { id: g.p.id })
      invalidate()
    }
    // A ghost the host has not taken back a few seconds after it was kept is
    // a proposal again (the host says why, if its write failed).
    function expireKept() {
      clearTimeout(state.ghostGoneTimer)
      state.ghostGoneTimer = setTimeout(() => {
        const now = performance.now()
        let changed = false
        for (const [id, gone] of state.ghostGone) {
          if (gone.kind === 'keeping' && now - gone.t >= 4000) { state.ghostGone.delete(id); changed = true }
        }
        if ([...state.ghostGone.values()].some(gone => gone.kind === 'keeping')) expireKept()
        if (changed) invalidate()
      }, 4100)
    }

    // ---- The Memory layer
    //
    // With the layer on, a card says how the cards Memory keeps about it
    // stand: a pip at its foot, green when all are holding, amber when any is
    // due, a muted red when any is fading (grey while some are not scheduled
    // yet); closer in their count, and in detail the whole line. A card
    // nothing was reviewed about for a long while is dusty: faint, under a
    // hatch. A region sums the cards it holds, and gathers dust itself when
    // most of what they hold is being forgotten.

    function markOf(ref) { return state.memory.enabled ? state.memory.marks.get(ref) || null : null }
    function memoryTone(m) {
      const c = state.colors
      return m.fading > 0 ? c.memFading : m.due > 0 ? c.memDue : m.solid >= m.cards ? c.memSolid : c.faint
    }
    function memoryText(m) {
      const parts = [m.cards + (m.cards === 1 ? ' card' : ' cards')]
      if (m.due) parts.push(m.due + ' due')
      if (m.fading) parts.push(m.fading + ' fading')
      return parts.join(' · ')
    }
    function sumMarks(refs) {
      let m = null
      for (const ref of refs) {
        const k = state.memory.marks.get(ref)
        if (!k) continue
        if (!m) m = { cards: 0, due: 0, fading: 0, solid: 0, marked: 0, dustyCards: 0 }
        m.cards += k.cards; m.due += k.due; m.fading += k.fading; m.solid += k.solid
        m.marked++
        if (k.dusty) m.dustyCards++
      }
      if (m) m.dusty = (m.cards >= 3 && m.fading * 2 > m.cards) || (m.marked >= 2 && m.dustyCards * 2 > m.marked)
      return m
    }
    function regionMemory(r) {
      if (!state.memory.enabled || !state.memory.marks.size) return null
      if (!state.regionMemo) state.regionMemo = new Map()
      if (!state.regionMemo.has(r.id)) state.regionMemo.set(r.id, sumMarks(refsInRegion(r)))
      return state.regionMemo.get(r.id)
    }
    // A pip of a tone; on a ring of the card's colour where it may sit on a
    // picture.
    function drawPip(cx, cy, tone, ringed) {
      if (ringed) { ctx.fillStyle = state.colors.card; ctx.beginPath(); ctx.arc(cx, cy, 5, 0, Math.PI * 2); ctx.fill() }
      ctx.fillStyle = tone
      ctx.beginPath(); ctx.arc(cx, cy, 3.5, 0, Math.PI * 2); ctx.fill()
    }
    // Closer in the pip sits on a small plate at the card's foot, with the
    // count (cards level) or the whole line (detail level).
    function memoryChip(m, x, y, h, L, pad) {
      const text = L === 2 ? String(m.cards) : memoryText(m)
      const size = L === 2 ? 10.5 : 11
      const font = (L === 2 ? '600 ' : '500 ') + size + 'px ' + state.font
      ctx.font = font
      const ch = L === 2 ? 16 : 18
      return { x: x + Math.max(5, pad * 0.6), y: y + h - Math.max(5, pad * 0.5) - ch, w: 24 + ctx.measureText(text).width, h: ch, text, font, size, tone: memoryTone(m) }
    }
    function drawMemoryChip(k) {
      const c = state.colors
      ctx.fillStyle = withAlpha(c.card, 0.92)
      roundRect(k.x, k.y, k.w, k.h, k.h / 2); ctx.fill()
      ctx.strokeStyle = withAlpha(c.text, 0.1); ctx.lineWidth = 1; ctx.stroke()
      drawPip(k.x + 9, k.y + k.h / 2, k.tone, false)
      ctx.font = k.font; ctx.fillStyle = c.sub
      ctx.fillText(k.text, k.x + 17, k.y + (k.h - k.size) / 2 - 0.5)
    }
    // Dust: a fine hatch over a card or region, tied to it so it pans with
    // it (a pattern, not a filter).
    function drawHatch(x, y, w, h, r) {
      const d = window.devicePixelRatio || 1
      if (!state.hatch || state.hatch.d !== d) {
        const size = 6
        const tile = document.createElement('canvas')
        tile.width = tile.height = Math.round(size * d)
        const g = tile.getContext('2d')
        g.scale(d, d)
        g.strokeStyle = state.dark ? 'rgba(255,255,255,0.16)' : 'rgba(80,64,40,0.16)'
        g.lineWidth = 0.9
        g.beginPath()
        g.moveTo(0, size); g.lineTo(size, 0)
        g.moveTo(-size / 2, size / 2); g.lineTo(size / 2, -size / 2)
        g.moveTo(size / 2, size * 1.5); g.lineTo(size * 1.5, size / 2)
        g.stroke()
        state.hatch = { d, pattern: ctx.createPattern(tile, 'repeat') }
      }
      const pattern = state.hatch.pattern
      if (!pattern) return
      if (pattern.setTransform) pattern.setTransform(new DOMMatrix([1 / d, 0, 0, 1 / d, x, y]))
      ctx.fillStyle = pattern
      roundRect(x, y, w, h, r); ctx.fill()
    }

    // ---- Written faces
    //
    // A source card's far, middle and near faces as ForeverLM wrote them
    // (never an Idea's: the learner's own words are never replaced): the far
    // face at the titles level when the card has no picture, the middle face
    // under the title closer in, and in detail the near points too.
    function faceOf(node) {
      if (!state.faces.enabled || node.kind === 'idea') return null
      return state.faces.map.get(node.ref) || null
    }

    // ---- Review in place
    //
    // Memory's review on the Canvas: the camera flies to each card reviewed,
    // which sits left of the middle at the size of a readable card, ringed,
    // with every other card faint, so where it is on the plane is a cue for
    // what it holds. The host draws the question to its right, at the spot
    // the page tells it. Only looking around (pan and zoom) works meanwhile.

    function reviewNode() { return state.review ? state.byRef.get(state.review.ref) || null : null }
    function reviewDim(node) {
      const rv = state.review
      if (!rv || node.ref === rv.ref) return 1
      const st = stackOf(node)
      return st && st.leader.ref === node.ref && st.refs.includes(rv.ref) ? 1 : 0.3
    }
    // The middle of the reviewed card as drawn, or for evidence not shown at
    // this zoom, where it hangs under its Idea.
    function reviewTarget(node) {
      const p = pos(node)
      if (p) { const [w, h] = sizeOf(node); return [p[0] + w / 2, p[1] + h / 2] }
      for (const [ideaRef, refs] of state.evidence) {
        const idea = placedBox(ideaRef)
        if (idea && refs.includes(node.ref)) return [idea.x + idea.w / 2, idea.y + idea.h + 26 + EV_H / 2]
      }
      return null
    }
    function beginReview(r) {
      if (!r || r.ref == null) return
      hidePeek()
      if (state.drag && state.drag.kind === 'ghost') state.drag = null
      if (!state.review) {
        const cam = state.camTarget || { scale: state.scale, ox: state.ox, oy: state.oy }
        state.review = { saved: { scale: cam.scale, ox: cam.ox, oy: cam.oy } }
      }
      Object.assign(state.review, { ref: String(r.ref), index: r.index, total: r.total, t0: performance.now(), sent: undefined, sentAt: -Infinity })
      state.hover = null; state.ghostHover = null; state.ghostPart = null
      canvas.style.cursor = 'grab'
      canvas.title = ''
      const node = reviewNode()
      const at = node && reviewTarget(node)
      if (at) {
        const s = clamp(REVIEW_W / CARD_W, MIN_SCALE, MAX_SCALE)
        flyCamera(s, viewW() * REVIEW_X - at[0] * s, viewH() / 2 - at[1] * s, REVIEW_MS, () => postReviewAnchor(true))
      } else postReviewAnchor(true)
      invalidate()
    }
    function finishReview() {
      const rv = state.review
      if (!rv) return
      clearTimeout(state.reviewTimer); state.reviewTimer = 0
      state.review = null
      flyCamera(rv.saved.scale, rv.saved.ox, rv.saved.oy, REVIEW_MS)
      canvas.style.cursor = cursorFor(null, false)
      invalidate()
    }
    // The reviewed card's rect on the page, or null when it is not drawn.
    function reviewRect() {
      const node = reviewNode()
      const p = node && pos(node)
      if (!p || folded(node) >= 1) return null
      const [w, h] = sizeOf(node)
      const [x, y] = toScreen(p[0], p[1])
      const sw = w * state.scale, sh = h * state.scale
      if (x > viewW() || y > viewH() || x + sw < 0 || y + sh < 0) return null
      return { x: round(x), y: round(y), w: round(sw), h: round(sh) }
    }
    // Told when a flight lands and, at most every 50 ms, whenever the
    // camera has moved the card.
    function postReviewAnchor(force) {
      const rv = state.review
      if (!rv) return
      const rect = reviewRect()
      const key = JSON.stringify(rect)
      if (!force && key === rv.sent) return
      const wait = REVIEW_ANCHOR_MS - (performance.now() - rv.sentAt)
      if (!force && wait > 0) {
        if (!state.reviewTimer) state.reviewTimer = setTimeout(() => { state.reviewTimer = 0; postReviewAnchor(false) }, wait)
        return
      }
      clearTimeout(state.reviewTimer); state.reviewTimer = 0
      rv.sent = key; rv.sentAt = performance.now()
      host.post('reviewAnchor', { ref: rv.ref, rect })
    }
    // A soft ring around the card reviewed, pulsing for a few seconds after
    // each flight, then still.
    function drawReviewRing(now) {
      const rv = state.review
      const node = reviewNode()
      const p = node && pos(node)
      if (!p) return
      const c = state.colors
      const [w, h] = sizeOf(node)
      const [x, y] = toScreen(p[0], p[1])
      const sw = w * state.scale, sh = h * state.scale
      const t = now - rv.t0
      const k = t < REVIEW_PULSE_MS ? 0.5 + 0.5 * Math.sin(t / 1100 * Math.PI * 2) : 0.5
      const off = 5 + 4 * k
      const radius = Math.max(4, (node.kind === 'idea' ? 4 : 12) * state.scale) + off
      ctx.save()
      ctx.shadowColor = withAlpha(c.select, 0.5); ctx.shadowBlur = 8 + 10 * k
      ctx.strokeStyle = withAlpha(c.select, 0.3 + 0.4 * k); ctx.lineWidth = 2.5
      roundRect(x - off, y - off, sw + off * 2, sh + off * 2, radius); ctx.stroke()
      ctx.restore()
      if (t < REVIEW_PULSE_MS) redraw()
    }

    // ---- Hit testing

    // The card under a point: a placed or lensed card over an Idea's
    // evidence under it. `except` leaves out the cards being dragged.
    function hitNode(px, py, except) {
      if (level() === 0 && state.scale * CARD_W < 6) return null
      const [x, y] = toWorld(px, py)
      let fanHit = null
      for (let i = state.nodes.length - 1; i >= 0; i--) {
        const node = state.nodes[i]
        if (state.lens && !inLens(node)) continue
        if (except && except.has(node.ref)) continue
        if (hiddenInStack(node)) continue
        if (folded(node) > 0.5) continue
        const p = pos(node)
        if (!p) continue
        const [w, h] = sizeOf(node)
        if (x >= p[0] && x <= p[0] + w && y >= p[1] && y <= p[1] + h) {
          if (!isFanned(node)) return node
          fanHit = fanHit || node
        }
      }
      return fanHit
    }
    // A placed Idea under a point that sources or Docs dropped there would
    // be linked to as evidence.
    function hitIdea(px, py, except) {
      const node = hitNode(px, py, except)
      return node && node.kind === 'idea' && state.placements[node.ref] ? node : null
    }
    function hitRegion(px, py) {
      if (state.lens) return null
      const [x, y] = toWorld(px, py)
      // A region's name (drawn above its frame closer in) is the frame's handle.
      for (let i = state.labelHits.length - 1; i >= 0; i--) {
        const b = state.labelHits[i]
        if (px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h) {
          const r = shownRegions().find(r => r.id === b.id)
          if (r) return { region: r, handle: false }
        }
      }
      let best = null
      for (const r of shownRegions()) {
        // A region shrunk away into its parent's face takes no press.
        if (tileK(r) >= 1) continue
        const onLabel = x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + Math.max(40, 40 / state.scale)
        const inside = x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h
        // A folded region's face is its handle, as a notebook's frame's is.
        if (onLabel || (inside && (level() === 0 || foldK() > 0.5))) {
          if (!best || r.w * r.h < best.region.w * best.region.h) best = { region: r, handle: false }
        }
      }
      return best
    }
    // Cards set down together: a grid about 3:2 wide with its top-left at
    // (x, y), and the region that would hold them with room for its name.
    function gridFrom(refs, x, y) {
      const cols = Math.max(1, Math.ceil(Math.sqrt(refs.length * 1.5)))
      // Each row as tall as its tallest card (a clip is as tall as its picture).
      const rowH = []
      refs.forEach((ref, i) => { const row = Math.floor(i / cols); rowH[row] = Math.max(rowH[row] || 0, cardH(state.byRef.get(ref))) })
      const rowY = []
      for (let row = 0, ry = y; row < rowH.length; row++) { rowY[row] = ry; ry += rowH[row] + GAP }
      const spots = refs.map((ref, i) => ({ ref, x: round(x + (i % cols) * (CARD_W + GAP)), y: round(rowY[Math.floor(i / cols)]) }))
      const w = cols * (CARD_W + GAP) - GAP, h = rowH.reduce((a, b) => a + b + GAP, 0) - GAP
      return { spots, region: { x: round(x - 50), y: round(y - 60), w: round(w + 100), h: round(h + 110) } }
    }

    function newRegionID() { return 'r' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6) }

    // Places `refs` as one block and, when `name` is given, draws a region
    // around them named after it: a notebook dropped from the Library sidebar
    // or the add box, or placed from either.
    function setDown(refs, x, y, name, notebookID) {
      const { spots, region } = gridFrom(refs, x, y)
      for (const spot of spots) state.placements[spot.ref] = spotAt(spot.ref, spot.x, spot.y)
      host.post('placed', { items: spots })
      if (name) {
        const id = newRegionID()
        const color = REGION_TINTS[Object.keys(state.regions).length % REGION_TINTS.length]
        const made = Object.assign({ id, name, color }, region, notebookID ? { notebookID } : {})
        state.regions[id] = made
        host.post('regionCreated', { region: made })
      }
      invalidate(); scheduleViewReport()
    }

    // ---- Setting cards down from the app
    //
    // The host sets cards down in two ways: at a point (`dropAt`: a drag let go,
    // the add box opened there) and with no point (`dropAtCenter`: a row's
    // Place on the Canvas, Place All, a find result). Either way the cards end
    // up selected and ringed, so the learner sees where they went.

    // Rings cards for 2.6 s: the rest of the plane dims and they wear the
    // selection's outline (a find does the same). A later ring takes the plane
    // over from an earlier one, so the earlier one's timer must not put it out:
    // each timer only clears the ring it began.
    function ringCards(refs) {
      const token = ++state.ringToken
      state.highlight = new Set(refs)
      setTimeout(() => {
        if (token !== state.ringToken) return
        state.highlight = new Set()
        invalidate()
      }, 2600)
    }

    // A notebook whose frame is on the plane already is not framed twice:
    // the frame is selected and shown instead.
    function showFrameOf(notebookID) {
      const frame = notebookID && Object.values(state.regions).find(r => r.notebookID === notebookID)
      if (!frame) return false
      selectRegion(frame.id)
      fitTo(paddedBounds(shownRegions().find(r => r.id === frame.id) || frame))
      return true
    }

    // The cards of `refs` the plane can set down (the ones the host has told
    // it of), or null when nothing is to be set down: while a card is reviewed
    // in place, or when the notebook's frame is already there.
    function placeable(refs, notebookID) {
      if (state.review) return null
      if (showFrameOf(notebookID)) return null
      const known = (refs || []).filter(ref => state.byRef.has(ref))
      return known.length ? known : null
    }

    // The box `refs` take set down as one block with their top-left at (x, y):
    // the cards' own sizes, and the frame's region too when a region is drawn
    // round them (it reaches 50 and 60 units out, so it must not sit on a card).
    function blockRect(refs, x, y, framed) {
      const { spots, region } = gridFrom(refs, x, y)
      let box = null
      for (const spot of spots) {
        const node = state.byRef.get(spot.ref)
        box = union(box, { x: spot.x, y: spot.y, w: cardW(node), h: cardH(node) })
      }
      return framed ? union(box, region) : box
    }

    // Set down where a point of the view is: the block centred on it, selected
    // and ringed. With `evidence`, sources or Docs let go on a placed Idea
    // become its evidence instead: that is for a drag. A set-down with no spot
    // of its own (Place on the Canvas) passes false, since whatever Idea sits
    // under the middle of the view was never what the learner pointed at.
    // Returns the block's box in world units, or null when the cards went in
    // as evidence.
    function dropCards(px, py, known, regionName, notebookID, evidence) {
      const idea = evidence && !regionName && known.every(ref => state.byRef.get(ref).kind !== 'idea') ? hitIdea(px, py) : null
      if (idea) { host.post('linkEvidence', { idea: idea.ref, refs: known }); return null }
      const [x, y] = toWorld(px, py)
      const cols = Math.max(1, Math.ceil(Math.sqrt(known.length * 1.5)))
      const left = x - Math.min(cols, known.length) * (CARD_W + GAP) / 2, top = y - CARD_H / 2
      const box = blockRect(known, left, top, !!regionName)
      setDown(known, left, top, regionName, notebookID)
      setSelection(known)
      ringCards(known)
      return box
    }

    // The boxes of the cards on the plane, but those in `except`: what a block
    // set down must not land on. A card is as big as it is (`sizeOf`), not
    // CARD_W by CARD_H.
    function placedBoxes(except) {
      const boxes = []
      for (const node of state.nodes) {
        if (except.has(node.ref) || hiddenByFold(node.ref)) continue
        const p = planePos(node)
        if (!p) continue
        const [w, h] = sizeOf(node)
        boxes.push({ x: p[0], y: p[1], w, h })
      }
      return boxes
    }
    function overlaps(a, b) { return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h }

    // After a set-down from the app, the learner should see the cards. The
    // camera stays when the block is wholly in view (40 points in from every
    // edge); else it pans, at the zoom it has, just far enough to bring the
    // block in; else (the block is bigger than the view at this zoom) it fits
    // the block with `anchor`, the cards it was set beside. A flight already
    // under way is judged by where it is going.
    function revealBlock(block, anchor) {
      const W = viewW(), H = viewH(), M = 40
      if (W < 2 || H < 2 || !block) return
      const cam = state.camTarget || { scale: state.scale, ox: state.ox, oy: state.oy }
      const left = block.x * cam.scale + cam.ox, top = block.y * cam.scale + cam.oy
      const right = left + block.w * cam.scale, bottom = top + block.h * cam.scale
      if (left >= M && top >= M && right <= W - M && bottom <= H - M) return
      if (right - left <= W - M * 2 && bottom - top <= H - M * 2) {
        const dx = left < M ? M - left : right > W - M ? W - M - right : 0
        const dy = top < M ? M - top : bottom > H - M ? H - M - bottom : 0
        flyCamera(cam.scale, cam.ox + dx, cam.oy + dy, 460)
        return
      }
      fitTo(paddedBounds(anchor ? union(anchor, block) : block))
    }

    function hitEdge(px, py) {
      if (level() === 0) return null
      for (const pl of state.edgePills) {
        if (px >= pl.x && px <= pl.x + pl.w && py >= pl.y && py <= pl.y + pl.h && state.edges[pl.id]) return state.edges[pl.id]
      }
      for (const e of Object.values(state.edges)) {
        if (!edgeShown(e)) continue
        const path = edgePath(e)
        if (!path) continue
        const pts = pathSamples(path).map(pt => toScreen(pt[0], pt[1]))
        for (let i = 1; i < pts.length; i++) {
          if (distToSegment(px, py, pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]) < 6) return e
        }
      }
      return null
    }
    function distToSegment(px, py, x1, y1, x2, y2) {
      const dx = x2 - x1, dy = y2 - y1
      const t = clamp(((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy || 1), 0, 1)
      return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))
    }
    function pointInPolygon(pt, poly) {
      let inside = false
      for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        const [xi, yi] = poly[i], [xj, yj] = poly[j]
        if (((yi > pt[1]) !== (yj > pt[1])) && (pt[0] < (xj - xi) * (pt[1] - yi) / (yj - yi) + xi)) inside = !inside
      }
      return inside
    }

    // ---- Peek
    //
    // Resting the pointer on a card whose words the zoom cuts short shows them
    // whole beside it: the full title, who and when, its notebooks, chats and
    // first highlight, an Idea's note, or a series' items. It goes as soon as
    // the pointer moves off, presses, scrolls or types; once one has shown, the
    // next card's comes at once, as tooltips do.
    const peekEl = document.createElement('div')
    peekEl.className = 'map-peek'
    peekEl.setAttribute('aria-hidden', 'true')
    document.body.appendChild(peekEl)
    let peekTimer = 0
    let peekWarmUntil = 0
    function schedulePeek(node) {
      clearTimeout(peekTimer)
      if (state.stickyPeek) return
      hidePeek()
      if (!node || state.drag) return
      peekTimer = setTimeout(() => showPeek(node), performance.now() < peekWarmUntil ? 40 : 450)
    }
    // A peek asked for with a tap of Space stays until the next tap, Esc, a
    // press or a key: only `hidePeek(true)` puts it away.
    function hidePeek(force) {
      clearTimeout(peekTimer)
      if (state.stickyPeek && !force) return
      state.stickyPeek = null
      if (!peekEl.classList.contains('shown')) return
      peekEl.classList.remove('shown')
      peekEl.setAttribute('aria-hidden', 'true')
      peekWarmUntil = performance.now() + 700
    }
    function showPeek(node, sticky) {
      if (!sticky && (state.drag || state.hover !== node.ref)) return
      const st = stackOf(node)
      // Close in, the card says all of it already (unless it was asked for).
      // (A mind map's node has only its words close in: its note, behind the ≡, is for the peek.)
      if (!sticky && level() >= 3 && !st && !(mindInfo(node) && ideaNote(node))) return
      const p = pos(node)
      if (!p) return
      peekEl.textContent = ''
      const add = (cls, text) => {
        const el = document.createElement('div')
        el.className = cls
        el.textContent = text
        peekEl.appendChild(el)
        return el
      }
      const type = st ? st.type : node.type
      const kind = add('peek-kind', st ? seriesWord(st.type, st.refs.length) : node.kind === 'idea' ? 'Idea' : (TYPE_NAMES[type] || 'Source'))
      kind.style.setProperty('--tint', TYPE_TINTS[type] || TYPE_TINTS.other)
      add('peek-title', st ? (st.title || node.title) : node.title)
      if (st) {
        const items = st.refs.map(ref => state.byRef.get(ref)).filter(Boolean)
        for (const n of items.slice(0, 7)) add('peek-item', n.title)
        if (items.length > 7) add('peek-more', 'and ' + (items.length - 7) + ' more')
        add('peek-hint', 'Double-click to fan out')
      } else if (node.kind === 'idea') {
        if (node.sub && node.sub !== 'Idea') add('peek-note', node.sub)
        const evidence = (state.evidence.get(node.ref) || []).length
        if (evidence) add('peek-detail', evidence === 1 ? '1 source as evidence' : evidence + ' sources as evidence')
      } else {
        if (node.sub) add('peek-sub', node.sub)
        for (const line of node.detail || []) add('peek-detail', line)
        if (!isPlaced(node) && stackLayout().frameOf.has(node.ref)) add('peek-hint', 'In this notebook, not placed by you yet')
      }
      peekEl.classList.add('shown')
      peekEl.setAttribute('aria-hidden', 'false')
      state.stickyPeek = sticky ? node.ref : null
      placePeek(node)
    }
    // Beside the card, on whichever side has room, inside the view.
    function placePeek(node) {
      const st = stackOf(node)
      const p = pos(node)
      if (!p) return
      const [w, h] = sizeOf(node)
      const [sx, sy] = toScreen(p[0], p[1])
      const cw = w * state.scale, ch = h * state.scale
      const pw = peekEl.offsetWidth, ph = peekEl.offsetHeight
      let x = sx + cw + 12
      let y = sy
      if (x + pw > viewW() - 10) x = sx - pw - 12
      if (x < 10) { x = clamp(sx + cw / 2 - pw / 2, 10, Math.max(10, viewW() - pw - 10)); y = sy + ch + 10 > viewH() - ph - 10 ? sy - ph - 10 : sy + ch + 10 }
      peekEl.style.transform = 'translate(' + Math.round(x) + 'px,' + Math.round(clamp(y, 10, Math.max(10, viewH() - ph - 10))) + 'px)'
    }
    // A sticky peek follows its card as the camera moves, and goes when the card does.
    function keepStickyPeek() {
      const ref = state.stickyPeek
      if (!ref) return
      const node = state.byRef.get(ref)
      if (!node || !pos(node)) { hidePeek(true); return }
      placePeek(node)
    }

    // ---- Editors over the plane
    //
    // Words are written where they are read: a field of HTML laid over the
    // thing's screen rect (an Idea's card, a region's name, an arrow's label),
    // following the camera while it is open. Only one is open at a time. The
    // plane's own keys rest while it has the focus, and the camera may still
    // pan and zoom under it. Return or a click elsewhere keeps what was
    // written, Esc leaves it as it was.

    function closeEditor(commit) {
      const ed = state.editor
      if (!ed || ed.closing) return
      ed.closing = true
      if (commit && ed.commit) ed.commit()
      else if (!commit && ed.cancel) ed.cancel()
      ed.el.remove()
      state.editor = null
      try { canvas.focus({ preventScroll: true }) } catch (err) { canvas.focus() }
      invalidate()
    }
    // A one-line field over a rect in screen points: `place()` says where it is
    // now ({x, y, w, h}), `commit(text)` takes what was written.
    function openLineEditor(spec) {
      closeEditor(true)
      const el = document.createElement('input')
      el.type = 'text'; el.className = 'map-line-editor'; el.value = spec.text || ''
      el.spellcheck = false; el.autocomplete = 'off'
      if (spec.font) el.style.font = spec.font
      if (spec.color) el.style.color = spec.color
      if (spec.placeholder) el.placeholder = spec.placeholder
      document.body.appendChild(el)
      const ed = state.editor = { kind: spec.kind, id: spec.id, el, place: spec.place, minW: spec.minW || 140, last: null, center: !!spec.center,
        commit: () => spec.commit(el.value.trim()), cancel: () => {} }
      el.addEventListener('keydown', (e) => {
        e.stopPropagation()
        // A key that is part of composing text (an IME) is not Return or Esc.
        if (e.isComposing || e.keyCode === 229) return
        if (e.key === 'Enter') { e.preventDefault(); closeEditor(true) }
        else if (e.key === 'Escape') { e.preventDefault(); closeEditor(false) }
      })
      el.addEventListener('blur', () => closeEditor(true))
      el.addEventListener('wheel', onWheel, { passive: false })
      positionEditor()
      el.focus(); el.select()
      return ed
    }
    // Keeps the open editor over what it edits, as the camera moves.
    function positionEditor() {
      const ed = state.editor
      if (!ed || ed.closing) return
      if (ed.kind === 'idea') return positionIdeaEditor(ed)
      if (ed.kind === 'annotation') return positionAnnotationEditor(ed)
      const r = ed.place()
      if (r) ed.last = r
      const q = ed.last
      if (!q) return
      const width = Math.round(Math.max(ed.minW, q.w + 24))
      ed.el.style.width = width + 'px'
      const left = ed.center ? q.x + q.w / 2 - width / 2 : q.x - 7
      ed.el.style.transform = 'translate(' + Math.round(left) + 'px,' + Math.round(q.y - 4) + 'px)'
    }

    // A region's name, written on the plane. A notebook's frame is named by its
    // notebook, so it is not edited here.
    function renameRegionOnPlane(id) {
      const r = state.regions[id]
      if (!r || notebookOf(r) || state.lens || state.review) return
      const place = () => {
        const hit = state.labelHits.find(b => b.id === id)
        return hit ? (hit.nameRect || { x: hit.x + 4, y: hit.y + 4, w: hit.w - 8, h: 20 }) : null
      }
      if (!place()) return
      openLineEditor({
        kind: 'region', id, text: r.name || '', placeholder: 'Untitled region', place,
        font: '600 14px ' + state.font, color: r.color || REGION_TINTS[0],
        commit: (text) => {
          const cur = state.regions[id]
          if (!cur || text === (cur.name || '')) return
          cur.name = text
          host.post('regionRenamed', { id, name: text })
          invalidate()
        },
      })
    }

    // ---- Editing an Idea in place
    //
    // An Idea is written where it sits: a field for its title and one for its
    // note over its card, on the card's own colour, scaled with the camera, so
    // the card seems to open (`positionIdeaEditor`). It opens on Return with
    // one Idea selected, on a double-click on an Idea, from the host's
    // `editIdea`, and blank on a double-click on the empty plane or the Note
    // tool. Esc leaves without writing (a new Idea vanishes); ⌘↩, a click
    // elsewhere or blur keeps the words: an existing Idea posts `ideaEdited`
    // (and `placementChanged {h}` when its words grew past the card), a new
    // one `ideaRequested`, drawn as a ghost until the host's layout returns.
    // Return in the title moves to the note, ⇧↩ is a newline; in a region laid
    // out as a mind map Return makes a sibling and Tab a child.
    function positionIdeaEditor(ed) {
      let x = ed.x, y = ed.y
      if (ed.ref) {
        const node = state.byRef.get(ed.ref)
        const p = node && pos(node)
        if (!p) return
        x = p[0]; y = p[1]
      }
      const [sx, sy] = toScreen(x, y)
      ed.el.style.transform = 'translate(' + (Math.round(sx * 100) / 100) + 'px,' + (Math.round(sy * 100) / 100) + 'px) scale(' + state.scale + ')'
    }
    // The camera comes to the card when it is too far out to read it or off the view.
    function revealForEdit(x, y, w, h) {
      const small = state.scale < 0.8
      const [sx, sy] = toScreen(x, y)
      const inside = sx >= 8 && sy >= 8 && sx + w * state.scale <= viewW() - 8 && sy + h * state.scale <= viewH() - 8
      if (!small && inside) return
      const s = small ? 1 : state.scale
      flyCamera(s, viewW() / 2 - (x + w / 2) * s, viewH() / 2 - (y + h / 2) * s, 320)
    }
    function openIdeaEditor(spec) {
      closeEditor(true)
      const c = state.colors
      const pal = spec.color ? ideaPalette(spec.color) : null
      const el = document.createElement('div')
      el.className = 'map-editor'
      // Plain words are written on the plane's own card colour.
      el.style.background = spec.plain ? c.card : pal ? pal.fill : c.sticky
      el.style.color = spec.plain ? c.text : pal ? pal.ink : c.stickyText
      el.style.width = spec.w + 'px'
      el.style.minHeight = spec.h + 'px'
      el.style.fontFamily = state.font
      // The card's foot line ("▤ n sources") keeps its room under the words.
      if (spec.evidence) el.style.paddingBottom = '26px'
      const title = document.createElement('textarea')
      title.className = 'ed-title'; title.rows = 1; title.placeholder = 'Title'; title.value = spec.title || ''
      const note = document.createElement('textarea')
      note.className = 'ed-note'; note.rows = 1; note.placeholder = 'Note'; note.value = spec.note || ''
      for (const t of [title, note]) { t.spellcheck = false; t.setAttribute('autocomplete', 'off') }
      el.append(title, note)
      document.body.appendChild(el)
      const fit = () => { for (const t of [title, note]) { t.style.height = '0'; t.style.height = t.scrollHeight + 'px' } }
      const ed = state.editor = {
        kind: 'idea', ref: spec.ref || null, el, titleEl: title, noteEl: note, x: spec.x, y: spec.y, w: spec.w, h0: spec.h,
        fresh: !!spec.fresh, regionID: spec.regionID || null, then: null, closing: false,
        commit: () => commitIdeaEditor(ed), cancel: () => cancelIdeaEditor(ed),
      }
      fit()
      title.addEventListener('input', fit)
      note.addEventListener('input', fit)
      const tree = !!spec.ref && treeRegionOf(spec.ref)
      el.addEventListener('keydown', (e) => {
        e.stopPropagation()
        if (e.isComposing || e.keyCode === 229) return
        const cmd = e.metaKey || e.ctrlKey
        if (e.key === 'Escape') { e.preventDefault(); closeEditor(false); return }
        if (e.key === 'Enter' && cmd) { e.preventDefault(); closeEditor(true); return }
        if (e.target === title) {
          if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault()
            if (tree) { ed.then = { sibling: true }; closeEditor(true) } else { note.focus(); note.setSelectionRange(note.value.length, note.value.length) }
          } else if (e.key === 'Tab' && !e.shiftKey) {
            e.preventDefault()
            if (tree) { ed.then = { child: true }; closeEditor(true) } else note.focus()
          }
        } else if (e.key === 'Tab') e.preventDefault()
      })
      el.addEventListener('focusout', (e) => { if (!e.relatedTarget || !el.contains(e.relatedTarget)) closeEditor(true) })
      el.addEventListener('wheel', onWheel, { passive: false })
      positionIdeaEditor(ed)
      revealForEdit(spec.x, spec.y, spec.w, spec.h)
      invalidate()
      title.focus()
      if (spec.fresh) title.select(); else title.setSelectionRange(title.value.length, title.value.length)
      return ed
    }
    // The mind-map region an Idea is in, if its region lays out as one.
    function treeRegionOf(ref) {
      const id = stackLayout().innermost.get(ref)
      const r = id && state.regions[id]
      return r && r.layout === 'tree' ? r : null
    }
    // What a field says: the title trimmed, the note trimmed; a note with no
    // title lends its first line.
    function ideaWords(ed) {
      let title = ed.titleEl.value.trim(), note = ed.noteEl.value.trim()
      if (!title && note) { const i = note.indexOf('\n'); title = i < 0 ? note : note.slice(0, i).trim(); note = i < 0 ? '' : note.slice(i + 1).trim() }
      return { title, note }
    }
    function commitIdeaEditor(ed) {
      const { title, note } = ideaWords(ed)
      const h = Math.max(CARD_H, Math.ceil(ed.el.offsetHeight))
      if (!ed.ref) {
        // A new Idea: nothing written, nothing made.
        if (!title && !note) return
        const regionID = regionAt({ x: ed.x, y: ed.y }, null)
        const body = { x: round(ed.x), y: round(ed.y), title, note }
        if (regionID) body.regionID = regionID
        state.pendingIdeas.push({ x: ed.x, y: ed.y, title, note, t: performance.now() })
        setTimeout(() => { state.pendingIdeas = state.pendingIdeas.filter(g => performance.now() - g.t < 4900); invalidate() }, 5000)
        host.post('ideaRequested', body)
        return
      }
      const node = state.byRef.get(ed.ref)
      if (!node) return
      if (!title) {
        // An Idea made empty for typing, left empty: forgotten.
        if (ed.fresh) host.post('deleteRequested', { refs: [ed.ref] })
        return
      }
      const changed = title !== node.title || note !== ideaNote(node)
      const p = state.placements[ed.ref]
      if (changed) {
        node.title = title; node.sub = note || 'Idea'; node._auto = null
        host.post('ideaEdited', { ref: ed.ref, title, note })
      }
      // Its words are all shown: the card keeps the height they needed (a mind
      // map's node is as big as its words, and keeps none of its own).
      if (p && !mindInfo(node) && Math.abs(h - ed.h0) > 1) {
        p.h = round(h)
        host.post('placementChanged', { items: [{ ref: ed.ref, h: round(h) }] })
      }
      if (ed.then && p) {
        const w = cardW(node)
        const region = treeRegionOf(ed.ref)
        const body = { title: '', edit: true }
        if (ed.then.child) { body.parentRef = ed.ref; body.x = round(p.x + w + 60); body.y = round(p.y) }
        else {
          body.parentRef = treeIndex().parent.get(ed.ref) || null; body.after = ed.ref
          body.x = round(p.x); body.y = round(p.y + cardH(node) + 24)
        }
        if (region) body.regionID = stackLayout().innermost.get(ed.ref)
        host.post('ideaRequested', body)
      }
    }
    function cancelIdeaEditor(ed) {
      // Esc on an Idea made empty for typing forgets it, as leaving it empty does.
      if (ed.ref && ed.fresh) {
        const { title } = ideaWords(ed)
        if (!title) host.post('deleteRequested', { refs: [ed.ref] })
      }
    }
    // Opens the editor on a placed Idea.
    function startIdeaEdit(ref, opts) {
      const node = state.byRef.get(ref)
      const p = state.placements[ref]
      if (!node || node.kind !== 'idea' || !p || state.lens || state.review) return false
      // Editing a folded card unfolds it.
      if (p.folded) { delete p.folded; host.post('placementChanged', { items: [{ ref, folded: null }] }); invalidate() }
      hidePeek()
      if (!(state.selection.size === 1 && state.selection.has(ref))) setSelection([ref])
      const at = pos(node) || [p.x, p.y]
      const [w, h] = sizeOf(node)
      // A mind map's node is small: its editor is at least 240 points wide.
      openIdeaEditor({
        ref, x: at[0], y: at[1], w: mindInfo(node) ? Math.max(w, 240) : w, h, title: node.title, note: ideaNote(node), color: p.color || null, fresh: !!(opts && opts.fresh),
        evidence: (state.evidence.get(ref) || []).length > 0, plain: isPlain(node),
      })
      return true
    }
    // ---- Editing the words about a card
    //
    // Opened by a double-click on them or the host's `editAnnotation(ref)`: a
    // field over the card's room for them, scaled with the camera as an Idea's
    // editor is, "Why is it on this canvas?" while empty. On a card with none
    // it opens under the card's foot and the card grows as the words come
    // (`annotationOf` reads what is typed). ⌘↩, a click elsewhere or blur
    // keeps the words (`placementChanged {annotation}`, null when emptied);
    // Esc leaves them as they were.
    const ANN_MIN_ROOM = ANN_PAD + ANN_LINE_H
    // The room's box in world units: the card's bottom `annotationH`, or for a
    // card with none yet the line it would take (under the card, or at the
    // bottom of a card the learner sized).
    function annotationBox(node) {
      const p = pos(node)
      const room = Math.max(annotationH(node), ANN_MIN_ROOM)
      const sized = placementOf(node) && placementOf(node).h > 0
      return { x: p[0], y: p[1] + (sized ? cardH(node) - room : ownH(node)), w: cardW(node), h: room }
    }
    function inAnnotation(node, px, py) {
      const room = annotationH(node)
      if (!room || node.kind === 'idea' || level() < 2 || !pos(node)) return false
      const b = annotationBox(node)
      const [x, y] = toScreen(b.x, b.y)
      return px >= x && px <= x + b.w * state.scale && py >= y && py <= y + b.h * state.scale
    }
    function positionAnnotationEditor(ed) {
      const node = state.byRef.get(ed.ref)
      if (!node || !pos(node)) return
      const b = annotationBox(node)
      const [sx, sy] = toScreen(b.x, b.y)
      ed.el.style.width = b.w + 'px'
      ed.el.style.height = b.h + 'px'
      ed.el.style.transform = 'translate(' + (Math.round(sx * 100) / 100) + 'px,' + (Math.round(sy * 100) / 100) + 'px) scale(' + state.scale + ')'
    }
    function commitAnnotation(ed) {
      const p = state.placements[ed.ref]
      if (!p) return
      const text = ed.ta.value.trim().slice(0, ANN_MAX_CHARS)
      if (text === (p.annotation || '')) return
      if (text) p.annotation = text; else delete p.annotation
      host.post('placementChanged', { items: [{ ref: ed.ref, annotation: text || null }] })
    }
    function openAnnotationEditor(node, text) {
      closeEditor(true)
      const c = state.colors
      const el = document.createElement('div')
      el.className = 'map-editor map-note-editor'
      // A page, a clip and a page face are white in either theme.
      const white = node.kind === 'clip' || node.kind === 'page' || isPageFace(node)
      el.style.background = white ? '#ffffff' : c.card
      el.style.color = white ? '#1d1d1f' : c.text
      el.style.fontFamily = state.font
      const ta = document.createElement('textarea')
      ta.className = 'ed-note'; ta.placeholder = 'Why is it on this canvas?'; ta.maxLength = ANN_MAX_CHARS; ta.value = text
      ta.spellcheck = false; ta.setAttribute('autocomplete', 'off')
      el.appendChild(ta)
      document.body.appendChild(el)
      const ed = state.editor = { kind: 'annotation', ref: node.ref, el, ta, text, closing: false, commit: () => commitAnnotation(ed), cancel: () => {} }
      ta.addEventListener('input', () => { ed.text = ta.value; invalidate() })
      el.addEventListener('keydown', (e) => {
        e.stopPropagation()
        if (e.isComposing || e.keyCode === 229) return
        if (e.key === 'Escape') { e.preventDefault(); closeEditor(false) }
        else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); closeEditor(true) }
      })
      el.addEventListener('focusout', (e) => { if (!e.relatedTarget || !el.contains(e.relatedTarget)) closeEditor(true) })
      el.addEventListener('wheel', onWheel, { passive: false })
      positionAnnotationEditor(ed)
      const b = annotationBox(node)
      revealForEdit(b.x, b.y, b.w, b.h)
      invalidate()
      ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length)
      return ed
    }
    function startAnnotationEdit(ref) {
      const node = state.byRef.get(ref)
      const p = state.placements[ref]
      if (!node || !p || node.kind === 'idea' || !pos(node) || state.lens || state.review) return false
      // Editing a folded card unfolds it.
      if (p.folded) { delete p.folded; host.post('placementChanged', { items: [{ ref, folded: null }] }); invalidate() }
      hidePeek()
      if (!(state.selection.size === 1 && state.selection.has(ref))) setSelection([ref])
      openAnnotationEditor(node, p.annotation || '')
      return true
    }
    // A blank editor for a new Idea whose middle is the world point (wx, wy).
    function newIdeaAt(wx, wy) {
      if (state.lens || state.review) return
      const w = CARD_W, h = CARD_H
      openIdeaEditor({ ref: null, x: round(wx - w / 2), y: round(wy - h / 2), w, h, title: '', note: '' })
    }
    // The copy of an Idea carried with ⌥-drag, until it is let go.
    function drawCarriedCopy(L, W, H) {
      const d = state.drag
      if (!d || d.kind !== 'altCard' || !d.copy) return
      const node = state.byRef.get(d.ref)
      if (!node) return
      ctx.save()
      ctx.globalAlpha = 0.85
      drawNode(node, L, W, H, false, { x: d.copy.x, y: d.copy.y, lifted: true })
      ctx.restore()
    }
    // New Ideas on their way to the host: drawn faintly where they were written
    // until the host's layout has them.
    function drawPendingIdeas(L, W, H) {
      if (!state.pendingIdeas.length) return
      for (const g of state.pendingIdeas) {
        ctx.save()
        ctx.globalAlpha = GHOST_ALPHA
        drawNode({ ref: 'proposal:pending', kind: 'idea', type: 'idea', title: g.title, sub: g.note || 'Idea' }, L, W, H, false, { x: g.x, y: g.y, lifted: false })
        ctx.restore()
      }
    }

    // ---- Input
    //
    // The pointer works as it does in Freeform and Heptabase. A press on a card
    // selects it and a drag carries it (with the series it heads, if it is a
    // stack); a drag across the empty plane draws a selection rectangle, adding
    // to the selection with ⇧; the plane pans with two fingers on the trackpad,
    // with Space held, with the middle button or with the Hand tool (H); a
    // pinch or ⌘-scroll zooms about the pointer. Double-click a card to open
    // it, a stack to fan it out, a region's name to zoom to it, and the empty
    // plane to write a note there.

    function localPoint(e) {
      const b = canvas.getBoundingClientRect()
      return [e.clientX - b.left, e.clientY - b.top]
    }
    // The pointer's last spot over the plane, as the host is told of a click:
    // view points and world units, the world point worked out from the camera
    // as it is now (the plane may have scrolled under a still pointer). Empty
    // when the pointer is not over the plane.
    function pointerSpot() {
      const p = state.pointer
      if (!p) return {}
      const [wx, wy] = toWorld(p[0], p[1])
      return { x: round(p[0]), y: round(p[1]), wx: round(wx), wy: round(wy) }
    }

    // A pinch as Safari's gesture events, which WebKit sends in place of wheel
    // events when its own page zoom is off (the Mac host also forwards the
    // trackpad's magnify itself, to `pinch`).
    let gestureScale = 0
    canvas.addEventListener('gesturestart', (e) => { e.preventDefault(); gestureScale = 1; hidePeek() })
    canvas.addEventListener('gesturechange', (e) => {
      e.preventDefault()
      if (!gestureScale) return
      const [px, py] = localPoint(e)
      zoomAt(e.scale / gestureScale, px, py)
      gestureScale = e.scale
    })
    canvas.addEventListener('gestureend', (e) => { e.preventDefault(); gestureScale = 0 })

    function onWheel(e) {
      e.preventDefault()
      hidePeek()
      const [px, py] = localPoint(e)
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? viewH() : 1
      if (e.ctrlKey || e.metaKey) {
        if (!gestureScale) zoomAt(Math.exp(-e.deltaY * unit * 0.01), px, py)
      } else {
        stopCamera()
        state.ox -= e.deltaX * unit; state.oy -= e.deltaY * unit
        redraw(); scheduleViewReport()
      }
    }
    canvas.addEventListener('wheel', onWheel, { passive: false })

    // The plane's own menu would offer Reload and Inspect; the host's native
    // menu replaces it. What was hit is selected (unless it already is), and
    // the host is told what and where: `contextMenu {kind: plane | cards |
    // region | edge, refs?, id?, x, y, wx, wy}`, the point in screen points
    // from the plane's top left and in world units.
    canvas.addEventListener('contextmenu', (e) => {
      e.preventDefault()
      if (state.editor) closeEditor(true)
      if (state.review) return
      hidePeek()
      const [px, py] = localPoint(e)
      const [wx, wy] = toWorld(px, py)
      const at = { x: round(px), y: round(py), wx: round(wx), wy: round(wy) }
      // A proposal is kept or dismissed with its own buttons.
      const ghost = state.tool === 'select' ? hitGhost(px, py) : null
      if (ghost) { pickGhost(ghost.id); return }
      if (state.lens) return
      const node = hitNode(px, py)
      if (node) {
        const st = stackOf(node)
        let refs
        if (state.selection.has(node.ref)) refs = [...state.selection]
        else { refs = st ? st.refs : [node.ref]; selectRegion(null); selectEdge(null); setSelection(refs) }
        host.post('contextMenu', Object.assign({ kind: 'cards', refs }, at))
        return
      }
      const edge = hitEdge(px, py)
      if (edge) { selectEdge(edge.id); host.post('contextMenu', Object.assign({ kind: 'edge', id: edge.id }, at)); return }
      const region = hitRegion(px, py)
      if (region) { selectRegion(region.region.id); host.post('contextMenu', Object.assign({ kind: 'region', id: region.region.id }, at)); return }
      setSelection([]); selectRegion(null); selectEdge(null)
      host.post('contextMenu', Object.assign({ kind: 'plane' }, at))
    })

    canvas.addEventListener('pointerdown', (e) => {
      if (e.ctrlKey && e.button === 0) return
      if (state.editor) closeEditor(true)
      canvas.focus()
      clearPreview()
      hidePeek(true)
      const [px, py] = localPoint(e)
      canvas.setPointerCapture(e.pointerId)
      stopCamera()
      // In a review in place a press only pans.
      if (e.button === 1 || state.spaceHeld || state.tool === 'hand' || (state.review && e.button === 0)) {
        state.drag = { kind: 'pan', px, py, ox: state.ox, oy: state.oy }
        canvas.style.cursor = 'grabbing'
        return
      }
      if (e.button !== 0) return
      // ⌥-click a card opens it beside the Canvas; ⌥-drag an Idea carries a copy
      // of it; ⌥-drag from anywhere else circles, as ever.
      if (e.altKey && !state.lens && !hitGhost(px, py)) {
        const hit = hitNode(px, py)
        if (hit) { state.drag = { kind: 'altCard', ref: stackOf(hit) ? stackOf(hit).leader.ref : hit.ref, idea: hit.kind === 'idea' && !stackOf(hit), px, py, moved: false, copy: null }; return }
      }
      const tool = e.altKey ? 'circle' : state.tool
      if (tool === 'circle') { state.lasso = [[px, py]]; redraw(); return }
      if (tool === 'region') { state.drag = { kind: 'newRegion', sx: px, sy: py, rect: { x: px, y: py, w: 0, h: 0 } }; return }
      if (tool === 'note') {
        const [wx, wy] = toWorld(px, py)
        newIdeaAt(wx, wy)
        setTool('select')
        return
      }
      // ForeverLM's proposals take a press before the cards under them: its
      // ✓ keeps one, its × dismisses it, and a ghost card can be carried to
      // where it should be kept.
      const ghost = tool === 'select' ? hitGhost(px, py) : null
      if (ghost) {
        if (ghost.part !== 'body') {
          state.ghostPressAt = performance.now()
          if (ghost.part === 'keep') keepGhost(ghost.id); else dismissGhost(ghost.id)
          return
        }
        pickGhost(ghost.id)
        const g = state.ghosts.get(ghost.id)
        if (g && g.kind === 'card') state.drag = { kind: 'ghost', id: g.id, px, py, x0: g.x, y0: g.y, x: g.x, y: g.y, moved: false }
        return
      }
      const pill = state.stackPills.find(b => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h)
      if (pill) { state.openStacks.delete(pill.key); invalidate(); return }
      const link = tool === 'select' ? hitConnectHandle(px, py) : null
      if (link && link.plus) { addTreeChild(link.ref); return }
      if (link) { state.drag = { kind: 'connect', from: link.ref, fx: link.wx, fy: link.wy, px, py, viaHandle: true }; return }
      const grip = tool === 'select' ? hitHandle(px, py) : null
      if (grip) { beginResize(grip, px, py); return }
      // The triangle before a region's name folds it up, or opens it again.
      const chev = tool === 'select' && !state.lens ? state.chevronHits.find(b => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h) : null
      if (chev && state.regions[chev.id]) {
        host.post('regionCollapsed', { id: chev.id, collapsed: !state.regions[chev.id].collapsed })
        return
      }
      const badge = tool === 'select' ? state.badgeHits.find(b => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h) : null
      if (badge && state.placements[badge.ref]) {
        delete state.placements[badge.ref].folded
        host.post('placementChanged', { items: [{ ref: badge.ref, folded: null }] })
        invalidate()
        return
      }
      const padlock = tool === 'select' && !state.lens ? state.lockHits.find(b => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h) : null
      if (padlock && state.regions[padlock.id]) {
        delete state.regions[padlock.id].locked
        host.post('regionLocked', { id: padlock.id, locked: false })
        invalidate()
        return
      }
      // A page face's ‹ › turn its page and a question's badge marks it answered or open: neither starts a drag.
      const turn = tool === 'select' && !state.lens ? hitPageStepper(px, py) : null
      if (turn) { if (turn.dir) turnPage(turn.ref, turn.dir); return }
      const asked = tool === 'select' && !state.lens ? state.questionHits.find(b => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h) : null
      if (asked) { toggleAnswered(asked.ref); return }
      const node = hitNode(px, py)
      if (tool === 'connect') {
        if (node) {
          const [nx, ny] = pos(node)
          const [nw, nh] = sizeOf(node)
          state.drag = { kind: 'connect', from: node.ref, fx: nx + nw / 2, fy: ny + nh / 2, px, py }
        } else {
          // From a region, too: its name or its face.
          const rg = hitRegion(px, py)
          if (rg) {
            const r = rg.region
            state.drag = { kind: 'connect', from: 'region:' + r.id, fx: r.x + r.w / 2, fy: r.y + r.h / 2, px, py }
          } else state.drag = { kind: 'pan', px, py, ox: state.ox, oy: state.oy }
        }
        return
      }
      if (node && !state.lens) {
        // Positions are read before the selection changes: selecting a card
        // under an Idea can fold the Idea's evidence away.
        const before = new Map(state.nodes.filter(n => basePos(n)).map(n => [n.ref, pos(n)]))
        const st = stackOf(node)
        if (st) setSelection(e.shiftKey ? [...state.selection, ...st.refs] : st.refs)
        else if (e.shiftKey) toggleSelection(node.ref)
        else if (!state.selection.has(node.ref)) setSelection([node.ref])
        const moving = [...state.selection].map(ref => state.byRef.get(ref)).filter(n => n && before.has(n.ref))
        // The plane holds still under the press (the layout at the press);
        // once the pointer moves the carried cards follow it and the rest
        // make room as they would on a drop.
        state.drag = {
          kind: 'cards', px, py, moved: false, ideaTarget: null, base: stackLayout(), preview: null, carrying: null,
          guides: [], overRegion: null, snapOff: false,
          // A card in a locked region is not carried: the press only selects.
          locked: moving.some(n => lockedRegionOf(n.ref)),
          // ⌘-click: a floating popup of the card, if the press is not a drag.
          cmdClick: e.metaKey ? (stackOf(node) ? stackOf(node).leader.ref : node.ref) : null,
          starts: moving.map(n => {
            const was = state.placements[n.ref]
            return { ref: n.ref, p: before.get(n.ref), placed: !!was, was: was ? Object.assign({}, was) : null }
          }),
        }
        state.selectedRegion = null; state.selectedEdge = null
        return
      }
      if (node && state.lens) { setSelection(e.shiftKey ? [...state.selection, node.ref] : [node.ref]); state.drag = { kind: 'pan', px, py, ox: state.ox, oy: state.oy }; return }
      const edge = hitEdge(px, py)
      if (edge) { selectEdge(edge.id); state.drag = null; return }
      const region = hitRegion(px, py)
      if (region) {
        selectRegion(region.region.id)
        const r = region.region
        // A locked region is selected, never moved.
        if (r.locked) { state.drag = { kind: 'locked', px, py }; return }
        state.drag = {
          kind: 'moveRegion', id: r.id, px, py, x: r.x, y: r.y, moved: false,
          // The cards' stored spots move with the frame; what the frame draws
          // (a folded series, closed-up rows) follows from them. A notebook's
          // cards drawn unplaced follow the frame on their own. The regions
          // inside it come along, with everything in them.
          cards: refsInRegion(r).filter(ref => state.placements[ref]).map(ref => ({ ref, p: [state.placements[ref].x, state.placements[ref].y] })),
          regions: descendantRegions(r.id).map(c => ({ id: c.id, x: c.x, y: c.y })),
        }
        return
      }
      // The empty plane: a selection rectangle.
      if (!e.shiftKey) { state.ghostSelected = null; setSelection([]); selectRegion(null); selectEdge(null) }
      state.drag = { kind: 'marquee', sx: px, sy: py, px, py, keep: new Set(state.selection), moved: false }
    })

    canvas.addEventListener('pointermove', (e) => {
      const [px, py] = localPoint(e)
      state.pointer = [px, py]
      if (state.lasso) { state.lasso.push([px, py]); redraw(); return }
      const d = state.drag
      if (state.spaceTap && !state.spaceTap.moved) {
        const sp = state.spaceTap
        if (!sp.at) sp.at = [px, py]
        else if (Math.abs(px - sp.at[0]) + Math.abs(py - sp.at[1]) > 4) sp.moved = true
      }
      if (!d) { hoverAt(px, py); return }
      const carried = d.kind === 'cards' || d.kind === 'moveRegion'
      const [lx, ly] = carried ? linkedPoint(px, py) : [px, py]
      let dx = (lx - d.px) / state.scale, dy = (ly - d.py) / state.scale
      if (d.kind === 'pan') {
        state.ox = d.ox + px - d.px; state.oy = d.oy + py - d.py
        scheduleViewReport(); redraw(); return
      }
      if (d.kind === 'marquee') { sweep(d, px, py); return }
      if (d.kind === 'altCard') {
        if (!d.moved && Math.abs(px - d.px) + Math.abs(py - d.py) > 3) {
          d.moved = true
          if (!d.idea) {
            // Not an Idea: ⌥-drag circles, from where the press began.
            state.drag = null
            state.lasso = [[d.px, d.py], [px, py]]
            redraw()
            return
          }
        }
        if (d.moved) {
          const node = state.byRef.get(d.ref), p = node && pos(node)
          if (p) d.copy = { x: p[0] + (px - d.px) / state.scale, y: p[1] + (py - d.py) / state.scale }
          canvas.style.cursor = 'copy'
          redraw()
        }
        return
      }
      if (d.kind === 'locked' || (d.kind === 'cards' && d.locked)) {
        if (Math.abs(px - d.px) + Math.abs(py - d.py) > 3) canvas.style.cursor = 'not-allowed'
        return
      }
      if (d.kind === 'ghost') {
        if (!d.moved && Math.abs(px - d.px) + Math.abs(py - d.py) > 3) { d.moved = true; hidePeek() }
        if (d.moved) { d.x = d.x0 + dx; d.y = d.y0 + dy }
        redraw()
        return
      }
      if (d.kind === 'cards') {
        if (!d.moved && Math.abs(px - d.px) + Math.abs(py - d.py) > 3) {
          d.moved = true
          d.carrying = new Set(d.starts.map(st => st.ref))
          hidePeek()
        }
        if (d.moved) {
          const lead = d.starts[0]
          const placeAt = (ddx, ddy) => {
            for (const st of d.starts) state.placements[st.ref] = spotAt(st.ref, st.p[0] + ddx, st.p[1] + ddy)
            d.preview = computeLayout(carriedPlacements(d), d.carrying, d.base.regionH, undefined, pinnedTrees(d))
          }
          placeAt(dx, dy)
          d.guides = []
          // Free cards line up with their neighbours; cards going into a region
          // laid out in rows take a slot there instead.
          if (lead && !state.lens && !e.metaKey && !d.preview.pos.has(lead.ref)) {
            const [sx, sy] = snapCarried(d, dx, dy)
            if (sx !== dx || sy !== dy) placeAt(sx, sy)
          }
          d.overRegion = lead ? regionAt(state.placements[lead.ref], lead.ref) : null
        }
        // Sources and Docs carried over a placed Idea become its evidence on
        // the drop.
        const linkable = d.moved && d.starts.every(st => { const n = state.byRef.get(st.ref); return n && n.kind !== 'idea' })
        const idea = linkable ? hitIdea(px, py, d.carrying) : null
        d.ideaTarget = idea ? idea.ref : null
        if (d.ideaTarget) d.guides = []
      } else if (d.kind === 'moveRegion') {
        const r = state.regions[d.id]
        if (Math.abs(px - d.px) + Math.abs(py - d.py) > 3) d.moved = true
        if (d.moved) {
          r.x = d.x + dx; r.y = d.y + dy
          for (const st of d.cards) state.placements[st.ref] = spotAt(st.ref, st.p[0] + dx, st.p[1] + dy)
          for (const c of d.regions || []) { const cr = state.regions[c.id]; if (cr) { cr.x = c.x + dx; cr.y = c.y + dy } }
        }
      } else if (d.kind === 'resizeRegion') {
        const r = state.regions[d.id]
        if (Math.abs(px - d.px) + Math.abs(py - d.py) > 2) d.moved = true
        let { x, y, w, h } = d
        if (d.dir.includes('e')) w = Math.max(MIN_REGION_W, d.w + dx)
        if (d.dir.includes('w')) { w = Math.max(MIN_REGION_W, d.w - dx); x = d.x + d.w - w }
        if (d.dir.includes('s')) h = Math.max(MIN_REGION_H, d.h + dy)
        if (d.dir.includes('n')) { h = Math.max(MIN_REGION_H, d.h - dy); y = d.y + d.h - h }
        r.x = x; r.y = y; r.w = w; r.h = h
      } else if (d.kind === 'resizeCard') {
        if (Math.abs(px - d.px) + Math.abs(py - d.py) > 2) d.moved = true
        if (d.moved) resizeCardTo(d, dx, dy)
      } else if (d.kind === 'newRegion') {
        d.rect = { x: Math.min(d.sx, px), y: Math.min(d.sy, py), w: Math.abs(px - d.sx), h: Math.abs(py - d.sy) }
      } else if (d.kind === 'connect') { d.px = px; d.py = py }
      if (carried || d.kind === 'resizeRegion') postDragPreview(d)
      invalidate()
    })

    // The selection rectangle: every card it touches is selected as it grows
    // (a stack with its whole series), added to what ⇧ kept.
    function sweep(d, px, py) {
      if (!d.moved && Math.abs(px - d.sx) + Math.abs(py - d.sy) > 3) d.moved = true
      d.px = px; d.py = py
      if (!d.moved) return
      const [ax, ay] = toWorld(Math.min(d.sx, px), Math.min(d.sy, py))
      const [bx, by] = toWorld(Math.max(d.sx, px), Math.max(d.sy, py))
      const got = new Set(d.keep)
      for (const node of state.nodes) {
        if (!shown(node) || hiddenInStack(node) || folded(node) > 0.5 || !inLens(node)) continue
        const p = pos(node)
        if (!p) continue
        const [w, h] = sizeOf(node)
        if (p[0] > bx || p[0] + w < ax || p[1] > by || p[1] + h < ay) continue
        const st = stackOf(node)
        if (st) for (const ref of st.refs) got.add(ref)
        else got.add(node.ref)
      }
      state.selection = got
      redraw()
    }

    function hoverAt(px, py) {
      // A review in place only looks around: no rings, no peeks.
      if (state.review) {
        if (state.hover) { state.hover = null; redraw() }
        canvas.style.cursor = 'grab'
        return
      }
      // A ghost answers the pointer before the cards under it, and its
      // buttons say what they do.
      const ghost = state.tool === 'select' && !state.spaceHeld ? hitGhost(px, py) : null
      const id = ghost ? ghost.id : null, part = ghost ? ghost.part : null
      if (id !== state.ghostHover || part !== state.ghostPart) { state.ghostHover = id; state.ghostPart = part; redraw() }
      const tip = part === 'keep' ? 'Keep' : part === 'dismiss' ? 'Dismiss' : ''
      if (canvas.title !== tip) canvas.title = tip
      if (ghost) {
        if (state.hover) { state.hover = null; redraw() }
        hidePeek()
        canvas.style.cursor = 'pointer'
        return
      }
      const handle = state.tool === 'select' && !state.spaceHeld ? hitConnectHandle(px, py) : null
      if (handle) {
        hidePeek()
        canvas.style.cursor = handle.plus ? 'pointer' : 'crosshair'
        return
      }
      const grip = state.tool === 'select' && !state.spaceHeld ? hitHandle(px, py) : null
      if (grip) {
        if (state.hover) { state.hover = null; redraw() }
        hidePeek()
        canvas.style.cursor = HANDLE_CURSORS[grip.dir]
        return
      }
      const node = hitNode(px, py)
      const onName = !node && state.labelHits.some(b => px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h)
      // The card under the pointer answers it with a faint ring, and a peek
      // when it rests there.
      const hover = node ? node.ref : null
      if (hover !== state.hover) { state.hover = hover; redraw(); schedulePeek(node) }
      canvas.style.cursor = cursorFor(node, onName)
    }
    function cursorFor(node, onName) {
      if (state.spaceHeld || state.tool === 'hand' || state.review) return 'grab'
      if (state.tool === 'circle' || state.tool === 'region' || state.tool === 'connect') return 'crosshair'
      if (state.tool === 'note') return 'copy'
      if (node) return 'pointer'
      if (onName) return 'move'
      return 'default'
    }

    canvas.addEventListener('pointerup', (e) => {
      const [px, py] = localPoint(e)
      if (state.lasso) {
        const poly = state.lasso.map(p => toWorld(p[0], p[1]))
        state.lasso = null
        if (poly.length > 4) {
          const got = state.nodes.filter(n => inLens(n) && shown(n)).filter(n => {
            const p = pos(n)
            const [w, h] = sizeOf(n)
            return p && pointInPolygon([p[0] + w / 2, p[1] + h / 2], poly)
          }).map(n => n.ref)
          setSelection(got)
          if (got.length) fitTo(paddedBounds(worldBounds(got)))
        }
        redraw()
        return
      }
      const d = state.drag
      state.drag = null
      canvas.style.cursor = cursorFor(hitNode(px, py), false)
      if (!d) return
      if (d.kind === 'marquee') {
        if (d.moved) host.post('selection', { refs: [...state.selection] })
        redraw()
        return
      }
      if (d.kind === 'altCard') {
        const node = state.byRef.get(d.ref)
        if (!d.moved) host.post('openBeside', { ref: d.ref })
        else if (d.copy && node && px >= 0 && py >= 0 && px <= viewW() && py <= viewH()) {
          const x = round(d.copy.x), y = round(d.copy.y)
          state.pendingIdeas.push({ x, y, title: node.title, note: ideaNote(node), t: performance.now() })
          setTimeout(() => { state.pendingIdeas = state.pendingIdeas.filter(g => performance.now() - g.t < 4900); invalidate() }, 5000)
          host.post('ideaRequested', { copyOf: d.ref, x, y })
        }
        invalidate()
        return
      }
      if (d.kind === 'ghost') {
        // A ghost carried and let go on the plane is kept there; let go
        // outside the view it goes back to its slot.
        if (d.moved && px >= 0 && py >= 0 && px <= viewW() && py <= viewH()) keepGhost(d.id, { x: d.x, y: d.y })
        invalidate()
        return
      }
      if (d.kind === 'cards' && d.moved && d.ideaTarget) {
        // Linked, not placed: a placed card goes back where it was, and a
        // card that was not placed leaves the plane again.
        for (const st of d.starts) {
          if (st.was) state.placements[st.ref] = st.was
          else delete state.placements[st.ref]
        }
        host.post('linkEvidence', { idea: d.ideaTarget, refs: d.starts.map(st => st.ref) })
      } else if (d.kind === 'cards' && !d.moved && d.cmdClick) {
        // ⌘-click: a popup card beside the card, told where it is on screen.
        const node = state.byRef.get(d.cmdClick), p = node && pos(node)
        if (p) {
          const [w, h] = sizeOf(node)
          const [x, y] = toScreen(p[0], p[1])
          host.post('popup', { ref: d.cmdClick, rect: { x: round(x), y: round(y), w: round(w * state.scale), h: round(h * state.scale) } })
        }
      } else if (d.kind === 'cards' && d.moved) {
        const items = d.starts.map(st => ({ ref: st.ref, x: round(state.placements[st.ref].x), y: round(state.placements[st.ref].y) }))
        // A region laid out in rows reads its cards in the reading order of
        // their stored spots. A card let go there is read against what the
        // learner sees, so the region's other cards are stored where they are
        // drawn first: the card lands in the slot it was let go over (the one
        // the preview showed), not where an old spot happens to sort. The
        // frame's stored height follows its rows, so a card let go below it is
        // never taken into it later.
        const preview = d.preview || d.base
        const touched = new Set()
        for (const [id, refs] of d.base.members) {
          const r = state.regions[id]
          if (!r) continue
          const was = refs.some(ref => d.carrying.has(ref))
          const now = d.starts.some(st => preview.members.get(id) && preview.members.get(id).includes(st.ref))
          if (!was && !now && !d.starts.some(st => (st.was && centerIn(st.was, r, st.ref)) || centerIn(state.placements[st.ref], r, st.ref))) continue
          touched.add(id)
          for (const ref of refs) {
            const p = d.base.pos.get(ref)
            const stored = state.placements[ref]
            if (d.carrying.has(ref) || !p || !stored || (stored.x === p[0] && stored.y === p[1])) continue
            state.placements[ref] = spotAt(ref, p[0], p[1])
            items.push({ ref, x: round(p[0]), y: round(p[1]) })
          }
        }
        growRegionsFor(d, preview)
        for (const [id, refs] of preview.members) if (refs.some(ref => d.carrying.has(ref))) touched.add(id)
        for (const id of touched) {
          const r = state.regions[id]
          const h = preview.regionH.get(id) != null ? preview.regionH.get(id) : d.base.regionH.get(id)
          const w = preview.regionW.get(id) != null ? preview.regionW.get(id) : d.base.regionW.get(id)
          if (!r) continue
          const growW = w != null && w > r.w + 0.5
          if ((h == null || Math.abs(r.h - h) < 0.5) && !growW) continue
          if (h != null) r.h = round(h)
          if (growW) r.w = round(w)
          host.post('regionChanged', { region: cleanRegion(r) })
        }
        host.post('placed', { items })
      } else if (d.kind === 'moveRegion' && d.moved) {
        const r = state.regions[d.id]
        host.post('regionChanged', { region: cleanRegion(r) })
        for (const c of d.regions || []) { const cr = state.regions[c.id]; if (cr) host.post('regionChanged', { region: cleanRegion(cr) }) }
        if (d.cards.length) host.post('placed', { items: d.cards.map(st => ({ ref: st.ref, x: round(state.placements[st.ref].x), y: round(state.placements[st.ref].y) })) })
      } else if (d.kind === 'resizeCard') {
        // Written as the learner left it: the new size (what changed), and the
        // card's spot when the top or left handle moved it.
        const p = state.placements[d.ref]
        if (d.moved && p) {
          const item = { ref: d.ref }
          if (p.w !== d.was.w) item.w = round(p.w)
          if (p.h !== d.was.h) item.h = round(p.h)
          if (d.aspect) { item.w = round(p.w || d.w); item.h = round(p.h || d.h) }
          if (p.x !== d.x || p.y !== d.y) host.post('placed', { items: [{ ref: d.ref, x: round(p.x), y: round(p.y) }] })
          if (item.w != null || item.h != null) host.post('placementChanged', { items: [item] })
          if (item.w != null) p.w = item.w
          if (item.h != null) p.h = item.h
        }
      } else if (d.kind === 'resizeRegion' && !d.moved) {
        // A press on a handle with no drag writes nothing.
      } else if (d.kind === 'resizeRegion') {
        // A frame laid out in rows is as tall as its rows.
        const r = state.regions[d.id]
        const lay = computeLayout(state.placements, undefined, undefined, d.members ? { id: d.id, refs: d.members } : null)
        if (lay.regionH.get(d.id) != null) r.h = round(lay.regionH.get(d.id))
        host.post('regionChanged', { region: cleanRegion(r) })
        // The cards are stored where the rows put them, so they are still in
        // the region (and in the same order) the next time it is read.
        const items = []
        for (const ref of d.members || []) {
          const p = lay.pos.get(ref), stored = state.placements[ref]
          if (!p || !stored || (stored.x === p[0] && stored.y === p[1])) continue
          state.placements[ref] = spotAt(ref, p[0], p[1])
          items.push({ ref, x: round(p[0]), y: round(p[1]) })
        }
        if (items.length) host.post('placed', { items })
      } else if (d.kind === 'newRegion') {
        if (d.rect.w > 20 && d.rect.h > 20) {
          const [x, y] = toWorld(d.rect.x, d.rect.y)
          makeRegion({ x: round(x), y: round(y), w: round(d.rect.w / state.scale), h: round(d.rect.h / state.scale) })
        }
        setTool('select')
      } else if (d.kind === 'connect') {
        const to = connectTarget(px, py, d.from)
        if (to) host.post('edgeRequested', { from: d.from, to })
      }
      if (d.previewed && state.link) host.post('dragPreview', { done: true })
      invalidate()
    })

    canvas.addEventListener('pointerleave', () => {
      state.pointer = null
      hidePeek()
      if (state.hover) { state.hover = null; redraw() }
      if (state.ghostHover) { state.ghostHover = null; state.ghostPart = null; redraw() }
      if (canvas.title) canvas.title = ''
    })

    canvas.addEventListener('dblclick', (e) => {
      const [px, py] = localPoint(e)
      if (state.tool !== 'select' || state.spaceHeld || state.review) return
      // A double-click on a ghost keeps it where it is drawn; the presses of
      // a double-click on its ✓ or × are those buttons' alone.
      if (performance.now() - state.ghostPressAt < 600) return
      const ghost = hitGhost(px, py)
      if (ghost) { if (ghost.part === 'body') keepGhost(ghost.id); return }
      const node = hitNode(px, py)
      const st = node && stackOf(node)
      // A series fanned out is ten cards again, none of them chosen: the press
      // that began the double-click selected the whole series, and carrying one
      // chapter next must not carry the other nine.
      if (st && st.region) { state.openStacks.add(st.key); setSelection([]); invalidate(); return }
      if (st) {
        const p = state.placements[st.leader.ref]
        const { spots } = gridFrom(st.refs, p.x, p.y)
        for (const spot of spots) state.placements[spot.ref] = spotAt(spot.ref, spot.x, spot.y)
        host.post('placed', { items: spots })
        invalidate(); scheduleViewReport(); return
      }
      // The pill of a page face never opens the paper; the words about a card are edited where they are read.
      if (hitPageStepper(px, py)) return
      if (node && node.kind === 'idea') { startIdeaEdit(node.ref); return }
      if (node && inAnnotation(node, px, py)) { startAnnotationEdit(node.ref); return }
      if (node) { host.post('open', { ref: node.ref }); return }
      const named = state.labelHits.find(b => b.nameRect && px >= b.nameRect.x - 4 && px <= b.nameRect.x + b.nameRect.w + 4 && py >= b.nameRect.y - 2 && py <= b.nameRect.y + b.nameRect.h + 2)
      if (named && !notebookOf(state.regions[named.id] || {})) { renameRegionOnPlane(named.id); return }
      const edge = state.lens ? null : hitEdge(px, py)
      if (edge) { openEdgeLabelEditor(edge.id); return }
      const region = hitRegion(px, py)
      if (region) { fitTo(paddedBounds(region.region)); return }
      // The empty plane: a note, written where the learner double-clicked.
      if (state.lens) return
      const [wx, wy] = toWorld(px, py)
      newIdeaAt(wx, wy)
    })

    canvas.addEventListener('keydown', (e) => {
      const W = viewW(), H = viewH()
      const cmd = e.metaKey || e.ctrlKey
      const stickyWas = !!state.stickyPeek
      hidePeek(true)
      if (e.key === ' ') {
        if (!state.spaceHeld) {
          state.spaceHeld = true
          if (!state.drag) canvas.style.cursor = 'grab'
          // A tap of Space (down and up within 250 ms, the pointer still) toggles the peek.
          state.spaceTap = { t: performance.now(), moved: false, stickyWas }
        }
        e.preventDefault()
        return
      }
      // In a review in place only looking around works; Escape is the
      // host's to answer.
      if (state.review) {
        if (e.key === 'Escape') host.post('reviewEscape', {})
        else if (cmd) return
        else if (e.key === '?') host.post('shortcuts', {})
        else if (e.key === '+' || e.key === '=') zoomBy(1.4, W / 2, H / 2)
        else if (e.key === '-' || e.key === '_') zoomBy(1 / 1.4, W / 2, H / 2)
        else if (e.key === '0') fitTo(allBounds())
        else return
        e.preventDefault()
        return
      }
      if (cmd) {
        const k = e.key.toLowerCase()
        if (k === 'z') host.post(e.shiftKey ? 'redo' : 'undo', {})
        else if (k === 'a') selectAll()
        else if (k === 'g') regionAroundSelection()
        // ⌘F: the host's find field takes the focus (the plain F zooms to the selection).
        else if (k === 'f' && !state.editor) host.post('findRequested', {})
        else if (e.key === 'ArrowUp') climbOut()
        else if (e.key === 'ArrowDown') diveIn()
        // ⌘[ and ⌘]: back and forward over the canvases opened in this window.
        else if (e.key === '[') host.post('navigate', { direction: 'back' })
        else if (e.key === ']') host.post('navigate', { direction: 'forward' })
        // ⌘⌫: the selection goes (an Idea to Trash, anything else off the Canvas).
        else if ((e.key === 'Backspace' || e.key === 'Delete') && state.selection.size) host.post('deleteRequested', { refs: [...state.selection] })
        // ⌘L: the selected cards join the chat's context (the bare L is the Library's).
        else if (k === 'l' && state.selection.size && !state.editor) host.post('chatContextRequested', { refs: [...state.selection] })
        else return
        e.preventDefault()
        return
      }
      if (e.key === 'Escape') {
        // Esc also stops speaking to the canvas, when the host is listening.
        host.post('voiceEscape', {})
        if (state.ghostSelected) { state.ghostSelected = null; redraw() }
        else if (state.tool !== 'select') setTool('select')
        else { setSelection([]); selectRegion(null); selectEdge(null) }
      } else if (e.key === 'Backspace' || e.key === 'Delete') {
        if (state.ghostSelected) dismissGhost(state.ghostSelected)
        else if (state.selectedEdge) host.post('edgeDeleted', { id: state.selectedEdge })
        else if (state.selectedRegion) host.post('regionDeleted', { id: state.selectedRegion })
        else if (state.selection.size) host.post('unplace', { refs: [...state.selection].filter(ref => state.placements[ref]) })
      } else if (e.key === 'Enter' && state.ghostSelected) keepGhost(state.ghostSelected)
      else if (e.key === 'Enter' && state.selectedRegion) diveIn()
      else if (e.key === 'Enter') {
        // One card selected (or one series, which opens at its first card).
        const refs = [...state.selection]
        const first = state.byRef.get(refs[0])
        const st = first && stackOf(first)
        const one = refs.length === 1 || (st && refs.length === st.refs.length && refs.every(ref => st.refs.includes(ref)))
        if (!one) return
        if (first && first.kind === 'idea' && !st) { startIdeaEdit(first.ref); e.preventDefault(); return }
        host.post('openBeside', { ref: st ? st.leader.ref : refs[0] })
      } else if ((e.key === 'PageUp' || e.key === 'PageDown') && onePageFace()) {
        turnPage(onePageFace().ref, e.key === 'PageDown' ? 1 : -1)
      } else if (e.key.startsWith('Arrow')) {
        // ⌥-arrows nudge the selection (⇧ five times as far); the arrows alone
        // walk to the nearest card that way (⇧ adds it to the selection), or
        // in Focus mode follow the arrows.
        if (e.altKey) { if (state.selection.size) nudge(e.key, e.shiftKey) }
        else if (!focusWalk(e.key)) walkTo(e.key, e.shiftKey)
      }
      // The shortcuts are the host's: a popover over the whole pane.
      else if (e.key === '?') host.post('shortcuts', {})
      else if (e.key === '+' || e.key === '=') zoomBy(1.4, W / 2, H / 2)
      else if (e.key === '-' || e.key === '_') zoomBy(1 / 1.4, W / 2, H / 2)
      else if (e.key === '0') fitTo(allBounds())
      else if ((e.key === 'f' || e.key === 'F') && state.selection.size) fitTo(paddedBounds(worldBounds([...state.selection])))
      // / asks the host for its add box, at the pointer when it is over the
      // plane; L shows or hides the host's Library sidebar. A held key does
      // not repeat them. Words being written on the plane keep their keys (an
      // editor stops them reaching this listener); the `editor` test is for
      // the case where one does get here.
      else if (e.key === '/' && !e.altKey && !e.repeat && !state.editor) host.post('addRequested', pointerSpot())
      else if ((e.key === 'l' || e.key === 'L') && !e.altKey && !cmd && !e.repeat && !state.editor) host.post('libraryToggled', {})
      // S: held, the host listens until it comes up; tapped, until the
      // learner pauses. What they say changes the canvas (KnowledgeMapVoice).
      else if ((e.key === 's' || e.key === 'S') && !e.altKey && !state.editor) {
        if (!e.repeat && !state.voiceHeld) { state.voiceHeld = true; host.post('voiceKey', { down: true }) }
      }
      else if (!e.altKey && TOOL_KEYS[e.key]) setTool(TOOL_KEYS[e.key])
      else return
      e.preventDefault()
    })
    canvas.addEventListener('keyup', (e) => {
      if ((e.key === 's' || e.key === 'S') && state.voiceHeld) {
        state.voiceHeld = false
        host.post('voiceKey', { down: false })
        return
      }
      if (e.key !== ' ') return
      state.spaceHeld = false
      if (!state.drag) canvas.style.cursor = cursorFor(null, false)
      // The tap: a peek of the one selected card that stays (a second tap puts it away).
      const tap = state.spaceTap
      state.spaceTap = null
      if (!tap || tap.moved || tap.stickyWas || performance.now() - tap.t > 250 || state.review || state.editor) return
      if (state.selection.size !== 1) return
      const node = state.byRef.get([...state.selection][0])
      if (node && pos(node)) showPeek(node, true)
    })
    window.addEventListener('blur', () => {
      state.spaceHeld = false
      hidePeek()
      // S held as the window lost the keyboard: its keyup never comes.
      if (state.voiceHeld) { state.voiceHeld = false; host.post('voiceKey', { down: false }) }
    })

    // The arrow keys alone: the nearest card in that direction from the
    // selection's middle (the smallest distance with the largest share of it
    // along the axis); with nothing selected, the one nearest the view's
    // middle. Nothing when there is none that way.
    function walkTo(key, extend) {
      if (state.lens || state.selectedRegion || state.selectedEdge) return
      const dir = { ArrowRight: [1, 0], ArrowLeft: [-1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[key]
      if (!dir) return
      const chosen = state.selection
      let from
      if (chosen.size) {
        const b = worldBounds([...chosen])
        if (!b) return
        from = [b.x + b.w / 2, b.y + b.h / 2]
      } else from = viewCentre()
      let best = null, bestScore = Infinity
      for (const node of state.nodes) {
        if (chosen.has(node.ref) || !shown(node) || hiddenInStack(node) || folded(node) > 0.5 || !inLens(node)) continue
        if (!isPlaced(node) && !stackLayout().pos.has(node.ref) && !isFanned(node)) continue
        const p = pos(node)
        if (!p) continue
        const [w, h] = sizeOf(node)
        const vx = p[0] + w / 2 - from[0], vy = p[1] + h / 2 - from[1]
        const along = vx * dir[0] + vy * dir[1]
        const dist = Math.hypot(vx, vy)
        if (!chosen.size) { if (dist < bestScore) { best = node; bestScore = dist } continue }
        if (along <= 0) continue
        const share = along / (dist || 1)
        if (share < 0.5) continue
        const score = dist / share
        if (score < bestScore) { best = node; bestScore = score }
      }
      if (!best) return
      const st = stackOf(best)
      const refs = st ? st.refs : [best.ref]
      selectRegion(null); selectEdge(null)
      setSelection(extend ? [...state.selection, ...refs] : refs)
      bringIntoView(best)
    }
    // The camera follows a card that is off the view (or near its edge), at the scale it has.
    function bringIntoView(node) {
      const p = pos(node)
      if (!p) return
      const [w, h] = sizeOf(node)
      const [sx, sy] = toScreen(p[0], p[1])
      const m = 40
      if (sx >= m && sy >= m && sx + w * state.scale <= viewW() - m && sy + h * state.scale <= viewH() - m) return
      const s = state.scale
      flyCamera(s, viewW() / 2 - (p[0] + w / 2) * s, viewH() / 2 - (p[1] + h / 2) * s, 260)
    }

    // ⌘A: every card on the plane (or in the lens).
    function selectAll() {
      const refs = state.nodes.filter(n => shown(n) && inLens(n) && (state.lens || isPlaced(n) || stackLayout().pos.has(n.ref))).map(n => n.ref)
      selectRegion(null); selectEdge(null)
      setSelection(refs)
    }

    // ⌘G: a region drawn around the selected cards, its name asked for next.
    function regionAroundSelection() {
      if (state.lens) return
      const b = worldBounds([...state.selection].filter(ref => { const n = state.byRef.get(ref); return n && !isFanned(n) }))
      if (!b) return
      makeRegion({ x: round(b.x - 50), y: round(b.y - 60), w: round(b.w + 100), h: round(b.h + 110) })
    }
    function makeRegion(rect) {
      const id = newRegionID()
      const color = REGION_TINTS[Object.keys(state.regions).length % REGION_TINTS.length]
      const region = Object.assign({ id, name: '', color }, rect)
      state.regions[id] = region
      selectRegion(id)
      host.post('regionCreated', { region })
      invalidate()
    }

    // The arrow keys move the selected free cards a step (⇧: five), on
    // screen, written once the keys rest. A card in a region laid out in rows
    // keeps its slot.
    function nudge(key, big) {
      const step = (big ? 40 : 8) / state.scale
      const [ddx, ddy] = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[key] || [0, 0]
      const flow = stackLayout().pos
      const moved = state.nudge || new Map()
      for (const ref of state.selection) {
        const p = state.placements[ref]
        if (!p || flow.has(ref) || lockedRegionOf(ref)) continue
        state.placements[ref] = spotAt(ref, p.x + ddx, p.y + ddy)
        moved.set(ref, state.placements[ref])
      }
      if (!moved.size) return
      state.nudge = moved
      invalidate()
      clearTimeout(state.nudgeTimer)
      state.nudgeTimer = setTimeout(() => {
        const items = [...state.nudge].map(([ref, p]) => ({ ref, x: round(p.x), y: round(p.y) }))
        state.nudge = null
        host.post('placed', { items })
      }, 350)
    }

    // A card let go with its middle in a region but its rect crossing the
    // region's edge grows the region to hold it, by the overlap plus 24 on each
    // side crossed (the regions around it grow to keep holding it). A card whose
    // middle is outside is not pulled in; a region laid out in rows hugs its
    // rows instead; a locked one is not resized.
    function growRegionsFor(d, preview) {
      const grown = new Map()
      for (const st of d.starts) {
        const node = state.byRef.get(st.ref), p = state.placements[st.ref]
        if (!node || !p || isFanned(node)) continue
        const id = regionAt(p, st.ref)
        const r = id && state.regions[id]
        if (!r || r.locked || preview.members.has(r.id) || notebookOf(r)) continue
        const w = cardW(node), h = cardH(node)
        let x = r.x, y = r.y, right = r.x + r.w, bottom = r.y + r.h
        if (p.x < x) x = p.x - 24
        if (p.y < y) y = p.y - 24
        if (p.x + w > right) right = p.x + w + 24
        if (p.y + h > bottom) bottom = p.y + h + 24
        if (x === r.x && y === r.y && right === r.x + r.w && bottom === r.y + r.h) continue
        r.x = round(x); r.y = round(y); r.w = round(right - x); r.h = round(bottom - y)
        grown.set(r.id, r)
      }
      for (const r of [...grown.values()]) {
        let child = r
        for (const a of ancestorRegions(r.id).reverse()) {
          if (a.locked) break
          let x = a.x, y = a.y, right = a.x + a.w, bottom = a.y + a.h
          if (child.x < x) x = child.x - 24
          if (child.y < y) y = child.y - 24
          if (child.x + child.w > right) right = child.x + child.w + 24
          if (child.y + child.h > bottom) bottom = child.y + child.h + 24
          if (x === a.x && y === a.y && right === a.x + a.w && bottom === a.y + a.h) break
          a.x = round(x); a.y = round(y); a.w = round(right - x); a.h = round(bottom - y)
          grown.set(a.id, a)
          child = a
        }
      }
      for (const r of grown.values()) host.post('regionChanged', { region: cleanRegion(r) })
    }

    function paddedBounds(b) { return b && { x: b.x - 60, y: b.y - 70, w: b.w + 120, h: b.h + 140 } }
    function round(v) { return Math.round(v * 10) / 10 }
    function cleanRegion(r) {
      const out = { id: r.id, name: r.name || '', x: round(r.x), y: round(r.y), w: round(r.w), h: round(r.h), color: r.color }
      if (r.notebookID) out.notebookID = r.notebookID
      if (r.collapsed) out.collapsed = true
      if (r.locked) out.locked = true
      if (r.layout) out.layout = r.layout
      return out
    }

    function setSelection(refs) {
      state.selection = new Set(refs)
      if (state.selection.size) state.ghostSelected = null
      host.post('selection', { refs: [...state.selection] })
      invalidate()
    }
    function toggleSelection(ref) {
      const next = new Set(state.selection)
      if (next.has(ref)) next.delete(ref); else next.add(ref)
      setSelection([...next])
    }
    function selectRegion(id) {
      if (state.selectedRegion === id) return
      state.selectedRegion = id
      if (id) { state.selectedEdge = null; state.selection = new Set(); state.ghostSelected = null }
      host.post('regionSelected', { id })
      invalidate()
    }
    function selectEdge(id) {
      if (state.selectedEdge === id) return
      state.selectedEdge = id
      if (id) { state.selectedRegion = null; state.selection = new Set(); state.ghostSelected = null }
      host.post('edgeSelected', { id })
      invalidate()
    }
    function setTool(tool) {
      state.tool = tool
      host.post('tool', { tool })
      canvas.style.cursor = cursorFor(null, false)
    }

    // ---- What the host hears about the view, for the chat's context.

    function scheduleViewReport() {
      clearTimeout(state.viewTimer)
      state.viewTimer = setTimeout(reportView, VIEW_REPORT_MS)
    }
    function reportView() {
      const [x0, y0] = toWorld(0, 0), [x1, y1] = toWorld(viewW(), viewH())
      const visible = []
      for (const node of state.nodes) {
        if (!inLens(node)) continue
        const p = pos(node)
        if (!p) continue
        const [w, h] = sizeOf(node)
        if (p[0] + w >= x0 && p[0] <= x1 && p[1] + h >= y0 && p[1] <= y1) visible.push(node.ref)
        if (visible.length >= 200) break
      }
      const regions = Object.values(state.regions).filter(r => !hidden().regions.has(r.id) && r.x + r.w >= x0 && r.x <= x1 && r.y + r.h >= y0 && r.y <= y1).map(r => r.id)
      // Nothing drawn in view (no card, region or proposal): the chrome's
      // Back to content pill.
      let ghostInView = false
      for (const g of state.ghosts.values()) {
        if (g.kind === 'card' && g.x + CARD_W >= x0 && g.x <= x1 && g.y + CARD_H >= y0 && g.y <= y1) { ghostInView = true; break }
      }
      host.post('view', {
        scale: Math.round(state.scale * 1000) / 1000,
        empty: !visible.length && !regions.length && !ghostInView,
        level: ['regions', 'titles', 'cards', 'detail'][level()],
        center: { x: round((x0 + x1) / 2), y: round((y0 + y1) / 2) },
        span: { w: round(x1 - x0), h: round(y1 - y0) },
        visibleRefs: visible, visibleRegionIDs: regions,
        // The regions framing the view, outermost first: the chrome's path.
        path: viewRegionPath().map(r => ({ id: r.id, name: regionName(r) })),
      })
    }

    // ---- Lens animation

    let lensAnim = 0
    function animateLens(onDone) {
      cancelAnimationFrame(lensAnim)
      const t0 = performance.now()
      state.lensT = 0
      const step = (t) => {
        state.lensT = Math.min(1, (t - t0) / LENS_MS)
        invalidate()
        if (state.lensT < 1) lensAnim = requestAnimationFrame(step)
        else { state.lensFrom = null; if (onDone) onDone() }
      }
      lensAnim = requestAnimationFrame(step)
    }

    // The first view shows everything, once both the cards and the learner's
    // layout have arrived.
    function firstFit() {
      if (!state.firstContent || !state.gotContent || !state.gotLayout) return
      state.firstContent = false
      fitTo(allBounds(), true)
    }

    // An edit the host asked for before its Idea arrived opens when it has
    // (it is forgotten after ten seconds).
    function tryPendingEdit() {
      const pe = state.pendingEdit
      if (!pe) return
      if (performance.now() - pe.t > 10000) { state.pendingEdit = null; return }
      if (startIdeaEdit(pe.ref, pe.opts)) state.pendingEdit = null
    }

    // ---- The host's API

    const api = {
      setContent(content) {
        state.nodes = content.nodes || []
        state.byRef = new Map(state.nodes.map(n => [n.ref, n]))
        state.links = content.links || []
        state.notebooks = new Map((content.notebooks || []).map(nb => [nb.id, nb]))
        for (const ref of [...state.selection]) if (!state.byRef.has(ref)) state.selection.delete(ref)
        // Each Idea's evidence: the sources and Docs it is linked to.
        state.evidence = new Map()
        for (const l of state.links) {
          if (l.kind !== 'idea' || !String(l.a).startsWith('idea:')) continue
          if (!state.evidence.has(l.a)) state.evidence.set(l.a, [])
          state.evidence.get(l.a).push(l.b)
        }
        state.gotContent = true
        firstFit()
        invalidate(); scheduleViewReport()
        tryPendingEdit()
      },
      setLayout(layout) {
        clearTimeout(state.previewTimer)
        state.preview = null
        state.previewRegion = null
        const had = state.placements
        state.placements = {}
        for (const [ref, p] of Object.entries(layout.placements || {})) {
          const q = { x: p.x, y: p.y }
          if (p.w > 0) q.w = p.w
          if (p.h > 0) q.h = p.h
          if (p.folded) q.folded = true
          if (p.color) q.color = p.color
          // What Sapience showed: the page a paper's card shows, the words about a
          // card on this canvas, an Idea as plain words, a question marked answered.
          if (p.page > 0) q.page = Math.round(p.page)
          if (typeof p.annotation === 'string' && p.annotation) q.annotation = p.annotation
          if (p.plain) q.plain = true
          if (p.answered) q.answered = true
          state.placements[ref] = q
        }
        state.regions = {}
        for (const [id, r] of Object.entries(layout.regions || {})) state.regions[id] = Object.assign({ id }, r)
        state.edges = {}
        for (const [id, e] of Object.entries(layout.edges || {})) state.edges[id] = Object.assign({ id }, e)
        state.treeCache = null
        if (state.selectedRegion && !state.regions[state.selectedRegion]) state.selectedRegion = null
        if (state.selectedEdge && !state.edges[state.selectedEdge]) state.selectedEdge = null
        // A card folded away is not selected any more.
        state.hiddenCache = null
        // A new Idea the host has placed takes the place of its ghost.
        if (state.pendingIdeas.length) {
          let born = 0
          for (const ref of Object.keys(state.placements)) if (ref.startsWith('idea:') && !had[ref]) born++
          if (born) { state.pendingIdeas.splice(0, born); invalidate() }
        }
        const gone = [...state.selection].filter(hiddenByFold)
        if (gone.length) { for (const ref of gone) state.selection.delete(ref); host.post('selection', { refs: [...state.selection] }) }
        state.gotLayout = true
        firstFit()
        invalidate(); scheduleViewReport()
        tryPendingEdit()
      },
      setTool,
      zoom(factor) { zoomBy(factor, viewW() / 2, viewH() / 2) },
      // A trackpad pinch, as the Mac hands it over: a factor about a point.
      pinch(factor, px, py) {
        if (!(factor > 0)) return
        hidePeek()
        zoomAt(factor, px, py)
      },
      // A two-finger double tap: close in on the card or region under the
      // pointer, or back out to everything when already there.
      smartZoom(px, py) {
        const node = hitNode(px, py)
        const [wx, wy] = toWorld(px, py)
        const region = !node && shownRegions().filter(r => wx >= r.x && wx <= r.x + r.w && wy >= r.y && wy <= r.y + r.h)
          .sort((a, b) => a.w * a.h - b.w * b.h)[0]
        const b = node ? worldBounds(stackOf(node) ? [stackOf(node).leader.ref] : [node.ref]) : region || null
        if (!b) { fitTo(allBounds()); return }
        const target = node ? { x: b.x - CARD_W * 0.6, y: b.y - CARD_H * 0.9, w: b.w + CARD_W * 1.2, h: b.h + CARD_H * 1.8 } : paddedBounds(b)
        const s = Math.min((viewW() - 120) / target.w, (viewH() - 120) / target.h)
        if (state.scale > s * 0.9) fitTo(allBounds()); else fitTo(target)
      },
      fit() { fitTo(allBounds()) },
      focus(refs, regionID) {
        let b = refs && refs.length ? worldBounds(refs) : null
        if (regionID && state.regions[regionID]) b = union(b, state.regions[regionID])
        if (b) fitTo(paddedBounds(b))
        if (refs && refs.length) ringCards(refs)
        invalidate()
      },
      // Sources, Docs or a notebook dropped from elsewhere in the app, at a
      // point in the view: set down as one block there, cards already on the
      // map moving with it; selected and ringed.
      dropAt(px, py, refs, regionName, notebookID) {
        // Nothing is set down while a card is reviewed in place, and a
        // notebook whose frame is there already is shown, not framed twice.
        const known = placeable(refs, notebookID)
        if (!known) return
        // Sources or Docs dropped on a placed Idea become its evidence.
        dropCards(px, py, known, regionName, notebookID, true)
      },
      // What the Library sidebar, the add box and a find result place when the
      // learner gave no point (Place on the Canvas, Place All, a pick from the
      // list). With cards selected, the block goes to their right, level with
      // their top and two gaps off, and moves down until it lands on no card;
      // the camera follows it (`revealBlock`). With none selected it goes in
      // the middle of the view. It never becomes an Idea's evidence: the card
      // that sits under the middle of the view was not what the learner chose.
      dropAtCenter(refs, regionName, notebookID) {
        const known = placeable(refs, notebookID)
        if (!known) return
        // The selection, but for cards being placed (placing a selected card
        // again must not anchor it to itself).
        const anchorRefs = [...state.selection].filter(ref => state.placements[ref] && !known.includes(ref))
        const anchor = anchorRefs.length ? worldBounds(anchorRefs) : null
        if (!anchor) {
          revealBlock(dropCards(viewW() / 2, viewH() / 2, known, regionName, notebookID, false), null)
          return
        }
        const size = blockRect(known, 0, 0, !!regionName)
        const left = anchor.x + anchor.w + GAP * 2
        const others = placedBoxes(new Set(known))
        // Down past whatever it lands on, to a GAP below it; 40 tries, then it
        // takes the last spot (a plane this full has no room worth looking for).
        let top = anchor.y
        for (let tries = 0; tries < 40; tries++) {
          const mine = { x: left, y: top, w: size.w, h: size.h }
          const hit = others.filter(o => overlaps(mine, o))
          if (!hit.length) break
          top = Math.max(...hit.map(o => o.y + o.h)) + GAP
        }
        // `size` was measured with the cards' top-left at the origin, so its
        // own x, y are the frame's offset from them (0 with no frame).
        setDown(known, left - size.x, top - size.y, regionName, notebookID)
        setSelection(known)
        ringCards(known)
        revealBlock({ x: left, y: top, w: size.w, h: size.h }, anchor)
      },
      select(refs) { setSelection(refs || []); if (refs && refs.length) fitTo(paddedBounds(worldBounds(refs))) },
      // A highlight the host asks for stays until it asks again, so a ring's
      // timer must not put it out.
      highlight(refs) { state.ringToken++; state.highlight = new Set(refs || []); invalidate() },
      selectRegion,
      selectEdge,
      applyLens(lens) {
        state.lensFrom = null
        state.lens = lens
        animateLens()
        let b = null
        for (const p of Object.values(lens.positions)) b = union(b, { x: p.x, y: p.y, w: CARD_W, h: CARD_H })
        for (const f of lens.frames || []) b = union(b, f)
        if (lens.axes && lens.axes.frame) b = union(b, lens.axes.frame)
        // The window extended to follows the other's camera rather than
        // flying on its own.
        if (b && !state.follows) fitTo(paddedBounds(b))
        scheduleViewReport()
      },
      clearLens() {
        if (!state.lens) return
        state.lensFrom = state.lens
        state.lens = null
        animateLens()
        scheduleViewReport()
      },
      refreshTheme: readTheme,
      // The plane as a PNG data URL (null when there is nothing to draw): the
      // bounds of `refs` when given, else of everything, padded; `scale` times
      // the world's size, lowered to keep a side under 8,192. The plane is
      // drawn once onto another canvas by the same `draw`, with the selection,
      // hover, handles, proposals, minimap and overlays left out.
      exportImage(scale, refs) {
        const list = Array.isArray(refs) && refs.length ? refs : null
        const b = paddedBounds(list ? worldBounds(list) : allBounds())
        if (!b || b.w <= 0 || b.h <= 0) return null
        let s = Number(scale) > 0 ? Number(scale) : 1
        const MAX_SIDE = 8192
        if (b.w * s > MAX_SIDE || b.h * s > MAX_SIDE) s = Math.min(MAX_SIDE / b.w, MAX_SIDE / b.h)
        const off = document.createElement('canvas')
        off.width = Math.max(1, Math.ceil(b.w * s)); off.height = Math.max(1, Math.ceil(b.h * s))
        const keep = {
          ctx, view: state.view, scale: state.scale, ox: state.ox, oy: state.oy, selection: state.selection,
          selectedRegion: state.selectedRegion, selectedEdge: state.selectedEdge, hover: state.hover, drag: state.drag,
          ghostSelected: state.ghostSelected, ghostHover: state.ghostHover, highlight: state.highlight, review: state.review,
          proposals: state.proposals, lasso: state.lasso, pendingIdeas: state.pendingIdeas, fan: state.fan,
          labelHits: state.labelHits, chevronHits: state.chevronHits, lockHits: state.lockHits, stackPills: state.stackPills,
          ghostHits: state.ghostHits, ghostButtons: state.ghostButtons, badgeHits: state.badgeHits, edgePills: state.edgePills, handles: state.handles,
          pageHits: state.pageHits, questionHits: state.questionHits, lifting: state.lifting,
        }
        let url = null
        try {
          ctx = off.getContext('2d')
          state.exporting = true
          state.view = { w: off.width, h: off.height }
          state.scale = s; state.ox = -b.x * s; state.oy = -b.y * s
          state.selection = new Set(); state.selectedRegion = null; state.selectedEdge = null; state.hover = null; state.drag = null
          state.ghostSelected = null; state.ghostHover = null; state.highlight = new Set(); state.review = null
          state.proposals = null; state.lasso = null; state.pendingIdeas = []
          state.bundleCache = null
          draw()
          url = off.toDataURL('image/png')
        } finally {
          ctx = keep.ctx
          state.exporting = false
          Object.assign(state, keep)
          state.bundleCache = null
          redraw()
        }
        return url
      },
      // This Mac's display switches: {minimap, focus}. A missing key is left as it is.
      setDisplay(display) {
        if (!display) return
        if ('focus' in display) state.display.focus = !!display.focus
        if ('minimap' in display) { state.display.minimap = !!display.minimap; minimapEl.style.display = state.display.minimap ? 'block' : 'none' }
        invalidate()
      },
      // A blank Idea for writing at a world point (the plane menu's New Idea Here).
      newIdea(wx, wy) { newIdeaAt(Number(wx) || 0, Number(wy) || 0) },
      // An arrow's label for writing on the plane (the arrow menu's Edit Label).
      editEdgeLabel(id) { openEdgeLabelEditor(id) },
      // Opens a region's name for writing on the plane (the host's Rename), the
      // camera coming to it first when its name is not drawn where it is.
      renameRegion(id) {
        const r = state.regions[id]
        if (!r || notebookOf(r) || state.lens || state.review) return
        const open = () => { draw(); renameRegionOnPlane(id) }
        draw()
        if (state.labelHits.some(b => b.id === id && b.nameRect)) { open(); return }
        fitTo(paddedBounds(r), false, 60, () => setTimeout(open, 40))
      },
      // The cards of a region where its layout draws them, written as their own
      // spots (and the region as tall and wide as it is drawn): the host asks
      // before it clears the region's tree layout, so the cards stay where the
      // tree put them.
      commitDrawnSpots(regionID) {
        const lay = stackLayout()
        const r = state.regions[regionID]
        const items = []
        for (const [ref, p] of lay.pos) {
          if (lay.innermost.get(ref) !== regionID || !state.placements[ref]) continue
          state.placements[ref] = spotAt(ref, p[0], p[1])
          items.push({ ref, x: round(p[0]), y: round(p[1]) })
        }
        if (items.length) host.post('placed', { items })
        if (r) {
          const h = lay.regionH.get(regionID), w = lay.regionW.get(regionID)
          if (h != null) r.h = round(h)
          if (w != null && w > r.w) r.w = round(w)
          host.post('regionChanged', { region: cleanRegion(r) })
        }
      },
      // Start editing an Idea in place (a new one the host just made, or from
      // its menu). `opts.fresh` says it was made empty for typing: its title
      // is selected, and leaving it empty forgets it. If the Idea has not come
      // yet it opens when it does.
      editIdea(ref, opts) {
        if (!startIdeaEdit(ref, opts)) state.pendingEdit = { ref, opts, t: performance.now() }
      },
      // The words about a card for writing in place (the menu's Annotate… and
      // Edit Annotation…): the editor opens over the card's room for them.
      editAnnotation(ref) { startAnnotationEdit(ref) },
      // Turns a page face's page by `delta` (the menu's Next Page and Previous Page).
      turnPage(ref, delta) { return turnPage(ref, Math.round(Number(delta)) || 0) },
      // Escape from the host: an open editor is left without writing (or kept
      // when `commit` is true).
      closeEditors(commit) { closeEditor(!!commit) },
      // The host links this page to the other window's while the Map is
      // extended to another display, and unlinks it (null) when that ends.
      // `edge` is the side of this view facing the other window and `gap` the
      // points of desk between them. `announce` sends this camera now (the
      // window extended from); `follows` waits to be given one and skips the
      // first fit and a lens's flight (the window extended to).
      setLink(link) {
        state.link = link && link.edge ? { edge: link.edge, gap: Math.max(0, Number(link.gap) || 0) } : null
        if (!state.link) { state.follows = false; state.lastCam = null; clearPreview(); return }
        if (link.follows) { state.follows = true; state.firstContent = false }
        state.lastCam = link.announce ? null : { scale: state.scale, ox: state.ox, oy: state.oy }
        if (link.announce) reportCamera()
      },
      // The camera the host derived from the other window's.
      setCamera(cam) {
        if (!cam || !(cam.scale > 0)) return
        stopCamera()
        pendingFit = null
        state.scale = clamp(cam.scale, MIN_SCALE, MAX_SCALE)
        state.ox = cam.ox; state.oy = cam.oy
        state.lastCam = { scale: state.scale, ox: state.ox, oy: state.oy }
        redraw(); scheduleViewReport()
      },
      // The other window's drag as it goes: {items, region}, then {done}.
      // The new layout replaces it when the drop is written.
      previewDrag(preview) {
        clearTimeout(state.previewTimer)
        if (!preview || preview.done) { state.previewTimer = setTimeout(clearPreview, 800); return }
        state.preview = new Map((preview.items || []).map(it => [it.ref, it]))
        state.previewRegion = preview.region || null
        invalidate()
      },
      // What the other window's page selected, and its tool, set here
      // without telling the host again.
      mirror(m) {
        if (!m) return
        if (m.selection) state.selection = new Set(m.selection.filter(ref => state.byRef.has(ref)))
        if ('region' in m) { state.selectedRegion = m.region || null; if (m.region) { state.selectedEdge = null; state.selection = new Set() } }
        if ('edge' in m) { state.selectedEdge = m.edge || null; if (m.edge) { state.selectedRegion = null; state.selection = new Set() } }
        if (m.tool) { state.tool = m.tool; canvas.style.cursor = m.tool === 'select' ? 'grab' : 'crosshair' }
        invalidate()
      },
      // The model's summaries of clusters and regions, by notebook name and
      // region id: {short, long}. Drawn under a cluster's name, marked as
      // ForeverLM's, never in place of the learner's words.
      // Pictures as the Mac renders them: {ref: data URL}, merged in batches.
      setThumbnails(thumbs) {
        for (const [ref, src] of Object.entries(thumbs || {})) {
          if (!src) { state.thumbs.delete(ref); continue }
          const img = new Image()
          img.onload = () => redraw()
          img.src = src
          state.thumbs.set(ref, img)
        }
        invalidate()
      },
      // What is drawn, in world units, for checks in the harness: each card's
      // spot and each frame as shown, the ghosts (with those kept or
      // dismissed here) and the card reviewed with its rect on the page.
      drawn() {
        const cards = {}
        for (const node of state.nodes) {
          const p = pos(node)
          if (!p || hiddenInStack(node)) continue
          const [w, h] = sizeOf(node)
          // Its face ('page', 'node', 'plain', 'card'), the page a page face shows, and the lines its annotation is drawn in.
          const face = isPageFace(node) ? 'page' : mindInfo(node) ? 'node' : isPlain(node) ? 'plain' : 'card'
          cards[node.ref] = { x: p[0], y: p[1], w, h, face, page: face === 'page' ? pageOf(node) : null, annotationLines: annotationLinesOf(node) }
        }
        const ghosts = {}
        for (const g of state.ghosts.values()) ghosts[g.id] = g.kind === 'card' ? { kind: g.kind, x: g.x, y: g.y } : { kind: g.kind }
        return {
          cards, regions: shownRegions().map(r => ({ id: r.id, x: r.x, y: r.y, w: r.w, h: r.h, cards: refsInRegion(r).length, parent: regionTree().parent.get(r.id) || null, tile: tileK(r), lines: faceLines(r) })),
          path: viewRegionPath().map(r => r.id),
          labels: state.labelHits.slice(), fold: foldK(), camera: { scale: state.scale, ox: state.ox, oy: state.oy },
          selection: [...state.selection], guides: state.drag && state.drag.guides ? state.drag.guides.slice() : [],
          moving: state.moves.size,
          ghosts, gone: Object.fromEntries([...state.ghostGone].map(([id, g]) => [id, g.kind])), picked: state.ghostSelected,
          ghostHits: state.ghostHits.map(h => ({ id: h.id, rect: h.rect, anchor: h.anchor })),
          review: state.review ? { ref: state.review.ref, rect: reviewRect() } : null,
          handles: state.handles.slice(),
          // The open editor's card or region or arrow, the display switches, and the minimap as drawn.
          editing: state.editor ? (state.editor.ref || state.editor.id || 'new') : null,
          display: Object.assign({}, state.display),
          minimap: state.display.minimap && mm.fit ? { w: MM_W, h: MM_H, dots: mm.dots, fit: Object.assign({}, mm.fit) } : null,
          // Each arrow's route as drawn (world points) and the labels' pills on the page.
          // A stanced arrow's side, and the junction of a bundle it is in.
          edges: Object.fromEntries(Object.values(state.edges).map(e => { const p = edgePath(e); return [e.id, p ? { kind: p.kind, start: p.pts[0], end: p.pts[p.pts.length - 1], mid: p.mid, stance: e.stance || null, bundle: p.bundle ? p.bundle.junction : null } : null] })),
          edgePills: state.edgePills.slice(),
        }
      },
      // How long a frame takes to draw, for the harness: {frames, mean,
      // median, max} in ms over `frames` frames drawn in a row, each with its
      // layout worked out again when `relayout` is set.
      measureDraw(frames, relayout) {
        const n = Math.max(1, Math.min(500, Math.round(frames) || 30))
        const times = []
        for (let i = 0; i < n; i++) {
          if (relayout) { state.stackCache = null; state.ghostsDirty = true; state.regionMemo = null }
          const t0 = performance.now()
          draw()
          times.push(performance.now() - t0)
        }
        times.sort((a, b) => a - b)
        const ms = (v) => Math.round(v * 100) / 100
        return { frames: n, mean: ms(times.reduce((a, b) => a + b, 0) / n), median: ms(times[n >> 1]), max: ms(times[n - 1]) }
      },
      setSummaries(summaries) {
        state.summaries = { clusters: (summaries && summaries.clusters) || {}, regions: (summaries && summaries.regions) || {} }
        redraw()
      },
      // ForeverLM's proposals for a selection ({id, tool, title, anchor,
      // proposals}), drawn as ghosts until kept or dismissed; null clears
      // them. A set with a new id is laid out afresh; the same set again keeps
      // its ghosts where they are.
      setProposals(set) {
        const next = set && Array.isArray(set.proposals) ? set : null
        const same = !!(next && state.proposals && next.id === state.proposals.id)
        const ids = new Set(next ? next.proposals.map(p => p && String(p.id)) : [])
        if (!same) {
          state.ghosts = new Map()
          state.ghostTree = null
          state.ghostGone = new Map()
          state.ghostSelected = null; state.ghostHover = null; state.ghostPart = null
        } else for (const id of [...state.ghostGone.keys()]) if (!ids.has(id)) state.ghostGone.delete(id)
        if (state.drag && state.drag.kind === 'ghost' && !(same && ids.has(state.drag.id))) state.drag = null
        state.proposals = next
        if (ghostLayoutReady()) layoutGhosts(true)
        else { state.ghostsDirty = true; state.ghostPosted = null }
        redraw()
      },
      // The Memory layer: {enabled, marks: {ref: {cards, due, fading, solid,
      // dusty, lastReviewedAt}}}. Turned off it hides and keeps the marks;
      // sent without marks it keeps the ones it has.
      setMemory(memory) {
        if (memory && memory.marks && typeof memory.marks === 'object') {
          const n = (v) => Math.max(0, Math.round(Number(v) || 0))
          const marks = new Map()
          for (const [ref, m] of Object.entries(memory.marks)) {
            if (!m) continue
            marks.set(ref, { cards: n(m.cards), due: n(m.due), fading: n(m.fading), solid: n(m.solid), dusty: !!m.dusty, lastReviewedAt: m.lastReviewedAt == null ? null : m.lastReviewedAt })
          }
          state.memory.marks = marks
        }
        state.memory.enabled = !!(memory && memory.enabled)
        state.regionMemo = null
        redraw()
      },
      // Written faces of source cards: {enabled, faces: {ref: {far, mid,
      // near: [string]}}}. Turned off it hides and keeps them; sent without
      // faces it keeps the ones it has.
      setFaces(faces) {
        if (faces && faces.faces && typeof faces.faces === 'object') {
          const text = (v) => typeof v === 'string' ? v.trim() : ''
          const map = new Map()
          for (const [ref, f] of Object.entries(faces.faces)) {
            if (!f) continue
            const face = { far: text(f.far), mid: text(f.mid), near: Array.isArray(f.near) ? f.near.map(text).filter(Boolean) : [] }
            if (face.far || face.mid || face.near.length) map.set(ref, face)
          }
          state.faces.map = map
        }
        state.faces.enabled = !!(faces && faces.enabled)
        redraw()
      },
      // Review in place: {ref, index, total} of the card to review. The
      // first remembers the camera; each flies to its card; the end flies
      // back and gives the Canvas back.
      startReview(review) { beginReview(review) },
      reviewFocus(review) { beginReview(review) },
      endReview() { finishReview() },
    }

    // ---- Boot

    readTheme()
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', readTheme)
    new ResizeObserver(() => {
      resize()
      if (pendingFit && viewW() > 1 && viewH() > 1) { const b = pendingFit; pendingFit = null; fitTo(b, true) }
      scheduleViewReport()
    }).observe(canvas)
    resize()
    // A window moved to a display of another pixel density redraws at it.
    const watchPixelRatio = () => {
      matchMedia('(resolution: ' + (window.devicePixelRatio || 1) + 'dppx)')
        .addEventListener('change', () => { resize(); watchPixelRatio() }, { once: true })
    }
    watchPixelRatio()
    state.ready = true
    host.post('ready', {})
    return api
  }

  window.ForeverLMKnowledgeMap = { create, CARD_W, CARD_H, sizes: { pageFaceFootHeight, pageFaceHeight, annotationHeight, treeNodeSize } }
})()
