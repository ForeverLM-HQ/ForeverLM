// A live team Page in the editor (docs/teams-design.md, "Live team Pages"):
// ties a LiveRoom (live-room.js) to the ProseMirror view Milkdown made.
//
// The room's Yjs document becomes the page's words through y-prosemirror's
// sync plugin, everyone's caret through its cursor plugin, and Undo through
// its undo plugin, which undoes only this writer's own steps (ProseMirror's
// history would undo a teammate's words as well). The plugins are added to the
// view's state once the room is ready and taken out again when the page
// closes, so a page that is not a team Page never carries them.
//
// Who saves: a writer's own Mac saves what that writer typed, as on any page,
// and tells the room the fingerprint of every body it reports. A teammate's
// words arrive marked out of the history, so they are never reported and never
// saved twice; they reach this Mac's copy of the page through iCloud, where
// the fingerprint says the body is the room's own and the editor leaves the
// page as it is. A body nobody in the room wrote (a chat's edit, an MCP
// client's) is applied by one member only, the room's leader, and reaches the
// others through the room.

import { keymap } from '@milkdown/kit/prose/keymap'
import { prosemirrorToYXmlFragment, redoCommand, undoCommand, yCursorPlugin, ySyncPlugin, yUndoPlugin } from 'y-prosemirror'
import { threeWayMerge } from '../../../../schema/js/text-merge.js'
import { LiveRoom, pageRoomKeys } from './live-room.js'

const livePluginMark = Symbol('foreverlm-live')

function marked(plugin) {
  plugin[livePluginMark] = true
  return plugin
}

function cursorBuilder(user) {
  const caret = document.createElement('span')
  caret.classList.add('live-caret')
  caret.style.setProperty('--live-color', user.color)
  caret.setAttribute('aria-hidden', 'true')
  const label = document.createElement('span')
  label.classList.add('live-caret-name')
  label.textContent = user.name
  caret.append(label)
  return caret
}

function selectionBuilder(user) {
  return { style: `background-color: ${user.color}33`, class: 'live-selection' }
}

/// The room's live state for one open page. `getView` returns the editor's
/// view; `onPeers` and `onStatus` tell the page who is here and whether it is
/// connected.
export class LivePage {
  constructor({ spaceKey, pageID, relayURL, name, color }, { getView, onPeers, onStatus, WebSocketImpl } = {}) {
    this.config = { spaceKey, pageID, relayURL, name, color }
    this.getView = getView
    this.onPeers = onPeers ?? (() => {})
    this.onStatus = onStatus ?? (() => {})
    this.WebSocketImpl = WebSocketImpl
    this.room = null
    this.installed = false
    this.stopped = false
  }

  async start() {
    const { roomID, key } = await pageRoomKeys(this.config.spaceKey, this.config.pageID)
    if (this.stopped) return
    this.room = new LiveRoom({
      roomID,
      key,
      relayURL: this.config.relayURL,
      user: { name: this.config.name, color: this.config.color },
      WebSocketImpl: this.WebSocketImpl ?? globalThis.WebSocket,
      callbacks: {
        onSeed: () => this.seed(),
        onSynced: () => this.install(),
        onRestart: () => this.uninstall(),
        onPeers: (peers) => this.onPeers(peers),
        onStatus: (status) => this.onStatus(status),
      },
    })
    this.room.connect()
  }

  stop() {
    this.stopped = true
    this.uninstall()
    this.room?.close()
    this.room = null
    this.onPeers([])
  }

  /// The first member in the room: the page as it opened becomes the room's.
  seed() {
    const view = this.getView()
    if (!view || !this.room) return
    prosemirrorToYXmlFragment(view.state.doc, this.room.fragment)
    this.install()
    this.room.ready()
  }

  install() {
    const view = this.getView()
    if (!view || !this.room || this.installed) return
    const plugins = [
      marked(keymap({ 'Mod-z': undoCommand, 'Mod-Shift-z': redoCommand, 'Mod-y': redoCommand })),
      marked(ySyncPlugin(this.room.fragment)),
      marked(yCursorPlugin(this.room.awareness, { cursorBuilder, selectionBuilder })),
      marked(yUndoPlugin()),
    ]
    const kept = view.state.plugins.filter((plugin) => !plugin[livePluginMark])
    view.updateState(view.state.reconfigure({ plugins: [...plugins, ...kept] }))
    this.installed = true
  }

  uninstall() {
    if (!this.installed) return
    this.installed = false
    const view = this.getView()
    if (!view) return
    view.updateState(view.state.reconfigure({ plugins: view.state.plugins.filter((plugin) => !plugin[livePluginMark]) }))
  }

  /// What the editor does with a body the host hands it for this page, the
  /// page standing at `current` (see the top of this file):
  /// `{ action: 'ignore' }`, or `{ action: 'apply', markdown }` with the text
  /// to put in. A change nobody in the room wrote is merged, line by line,
  /// into the room's words against the room's newest save this member knows
  /// (`fallbackBase`, the text the host last heard, when it knows none), so
  /// a chat's edit made on an older copy never takes back what was typed
  /// since. When both changed the same lines the room's words stand and the
  /// change stays in the page's history.
  decide(markdown, current, fallbackBase) {
    const room = this.room
    if (!room || !this.installed) return { action: 'apply', markdown }
    if (room.isSavedByRoom(markdown)) {
      room.rememberText(markdown)
      return { action: 'ignore' }
    }
    if (!room.hasOthers()) return { action: 'apply', markdown }
    if (!room.isLeader()) return { action: 'ignore' }
    const base = room.latestKnownSaved() ?? fallbackBase
    if (base == null || current == null) return { action: 'apply', markdown }
    const result = threeWayMerge(base, current, markdown)
    if (result.conflict) return { action: 'ignore', conflict: true }
    return result.merged === current ? { action: 'ignore' } : { action: 'apply', markdown: result.merged }
  }

  noteSaved(markdown) {
    this.room?.noteSaved(markdown)
  }

  /// Undo and Redo of this writer's own steps; false when the room is not live.
  history(action, view) {
    if (!this.installed || !view) return false
    return (action === 'redo' ? redoCommand : undoCommand)(view.state, view.dispatch) === true
  }
}

const initials = (name) => {
  const words = String(name || '?').trim().split(/\s+/).filter(Boolean)
  return ((words[0]?.[0] ?? '?') + (words.length > 1 ? words[words.length - 1][0] : '')).toUpperCase()
}

/// The quiet row of who else is on the page, top right; nothing when alone.
export function renderPeers(container, peers, status) {
  if (!container) return
  const others = peers.filter((peer) => !peer.self)
  container.replaceChildren()
  container.hidden = others.length === 0 && status !== 'offline'
  container.classList.toggle('is-offline', status === 'offline')
  if (status === 'offline') {
    const note = document.createElement('span')
    note.className = 'live-peers-offline'
    note.textContent = 'Reconnecting…'
    container.append(note)
    return
  }
  for (const peer of others.slice(0, 5)) {
    const badge = document.createElement('span')
    badge.className = 'live-peer'
    badge.style.setProperty('--live-color', peer.color)
    badge.textContent = initials(peer.name)
    badge.title = peer.name
    badge.setAttribute('aria-label', `${peer.name} is on this page`)
    container.append(badge)
  }
  if (others.length > 5) {
    const more = document.createElement('span')
    more.className = 'live-peer live-peer-more'
    more.textContent = `+${others.length - 5}`
    more.title = others.slice(5).map((peer) => peer.name).join(', ')
    container.append(more)
  }
}
