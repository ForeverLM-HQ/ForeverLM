// A live Page room (docs/teams-design.md, "Live team Pages"): several members
// write one team Page at once. The page's words are a Yjs document every
// member's editor holds; the relay (workers/page-live, live.foreverlm.com) is a
// Durable Object per room that passes each member's messages to the others and
// never reads them. Everything a member sends is sealed with AES-GCM under a
// key only the space's members hold: the space's live key (a Setting in the
// space's zone) stretched with HKDF over the page's id. The room is named by
// the SHA-256 of that page key, so the relay learns neither the key nor which
// page it is.
//
// This file is the room alone (keys, the wire, the Yjs sync and awareness
// protocol, who seeds the room, who is leader) and knows nothing of the
// editor, so the node tests run two rooms against a fake relay. live-editor.js
// ties a room to the ProseMirror view.

import * as Y from 'yjs'
import * as awarenessProtocol from 'y-protocols/awareness'
import * as syncProtocol from 'y-protocols/sync'
import * as decoding from 'lib0/decoding'
import * as encoding from 'lib0/encoding'

/// What a sealed frame carries, its first byte once opened.
export const LiveMessage = Object.freeze({ sync: 0, awareness: 1, saved: 2 })

const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder()

export function base64urlToBytes(value) {
  const base64 = String(value).replace(/-/g, '+').replace(/_/g, '/')
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4)
  const binary = atob(padded)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index)
  return bytes
}

function hex(bytes) {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

/// The page's own key and the room's name, from the space's live key.
/// The same three steps run in every client, so every member lands in one room.
export async function pageRoomKeys(spaceKey, pageID, subtle = globalThis.crypto.subtle) {
  const spaceBytes = base64urlToBytes(spaceKey)
  if (spaceBytes.length < 32) throw new Error('The space live key is too short.')
  const base = await subtle.importKey('raw', spaceBytes, 'HKDF', false, ['deriveBits'])
  const pageBits = await subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: textEncoder.encode('foreverlm-page-live-v1'), info: textEncoder.encode(String(pageID)) },
    base,
    256
  )
  const roomID = hex(await subtle.digest('SHA-256', pageBits))
  const key = await subtle.importKey('raw', pageBits, 'AES-GCM', false, ['encrypt', 'decrypt'])
  return { roomID, key }
}

export async function seal(key, plaintext, subtle = globalThis.crypto.subtle) {
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12))
  const sealed = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv }, key, plaintext))
  const frame = new Uint8Array(iv.length + sealed.length)
  frame.set(iv, 0)
  frame.set(sealed, iv.length)
  return frame
}

/// The frame's message, or null when it was not sealed under this key.
export async function open(key, frame, subtle = globalThis.crypto.subtle) {
  const bytes = new Uint8Array(frame)
  if (bytes.length < 13) return null
  try {
    return new Uint8Array(await subtle.decrypt({ name: 'AES-GCM', iv: bytes.subarray(0, 12) }, key, bytes.subarray(12)))
  } catch {
    return null
  }
}

/// A short fingerprint of a body, to tell the room's own saves coming back
/// through iCloud from a change made elsewhere. Not a secret: it never leaves
/// the sealed frames.
export function bodyFingerprint(markdown) {
  const text = String(markdown ?? '')
  let h1 = 0xdeadbeef
  let h2 = 0x41c6ce57
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index)
    h1 = Math.imul(h1 ^ code, 2654435761)
    h2 = Math.imul(h2 ^ code, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return `${(h2 >>> 0).toString(16).padStart(8, '0')}${(h1 >>> 0).toString(16).padStart(8, '0')}:${text.length}`
}

const remoteOrigin = Symbol('live-room-remote')

/// One member's place in one page's room.
///
/// Callbacks:
/// - `onSeed()`: this member is the first in the room. It fills the room's
///   document from the page it has (`room.doc`) and then calls `ready()`.
/// - `onSynced()`: the room's document has arrived from the others.
/// - `onRestart()`: the room was emptied and begun again while this member was
///   away. The editor lets go of the old document here; the room then makes a
///   new one and starts over (seed or sync).
/// - `onPeers(list)`: who is here, from awareness: `[{ clientID, name, color, self }]`.
/// - `onStatus(status)`: `connecting`, `live`, `offline`.
export class LiveRoom {
  constructor({ roomID, key, relayURL, user, WebSocketImpl = globalThis.WebSocket, subtle = globalThis.crypto?.subtle, callbacks = {} }) {
    this.roomID = roomID
    this.key = key
    this.relayURL = String(relayURL).replace(/\/+$/, '')
    this.user = user
    this.WebSocketImpl = WebSocketImpl
    this.subtle = subtle
    this.callbacks = callbacks
    this.doc = new Y.Doc()
    this.fragment = this.doc.getXmlFragment('prosemirror')
    this.awareness = new awarenessProtocol.Awareness(this.doc)
    this.awareness.setLocalStateField('user', { name: user.name, color: user.color })
    this.savedFingerprints = new Map()
    this.knownTexts = new Map()
    this.epoch = null
    this.synced = false
    this.closed = false
    this.socket = null
    this.retry = 0
    this.retryTimer = null
    this.syncTimer = null
    this.sendQueue = Promise.resolve()
    this.status = 'connecting'

    this.onDocUpdate = (update, origin) => {
      if (origin === remoteOrigin || !this.synced) return
      const encoder = encoding.createEncoder()
      syncProtocol.writeUpdate(encoder, update)
      this.sendMessage(LiveMessage.sync, encoding.toUint8Array(encoder))
    }
    this.doc.on('update', this.onDocUpdate)

    this.onAwarenessUpdate = ({ added, updated, removed }, origin) => {
      const changed = added.concat(updated, removed)
      if (origin !== remoteOrigin) {
        this.sendMessage(LiveMessage.awareness, awarenessProtocol.encodeAwarenessUpdate(this.awareness, changed))
      }
      this.callbacks.onPeers?.(this.peers())
    }
    this.awareness.on('update', this.onAwarenessUpdate)
  }

  connect() {
    if (this.closed) return
    this.setStatus(this.status === 'live' ? 'connecting' : this.status)
    const socket = new this.WebSocketImpl(`${this.relayURL}/room/${this.roomID}`)
    socket.binaryType = 'arraybuffer'
    this.socket = socket
    socket.onmessage = (event) => this.receive(event.data)
    socket.onclose = () => {
      if (this.socket !== socket) return
      this.socket = null
      clearTimeout(this.syncTimer)
      if (this.closed) return
      this.setStatus('offline')
      // Everyone else's cursor is stale until the room answers again.
      awarenessProtocol.removeAwarenessStates(
        this.awareness,
        Array.from(this.awareness.getStates().keys()).filter((id) => id !== this.doc.clientID),
        remoteOrigin
      )
      const delay = Math.min(30_000, 500 * 2 ** this.retry) * (0.75 + Math.random() * 0.5)
      this.retry += 1
      this.retryTimer = setTimeout(() => this.connect(), delay)
    }
    socket.onerror = () => {}
  }

  close() {
    this.closed = true
    clearTimeout(this.retryTimer)
    clearTimeout(this.syncTimer)
    try {
      awarenessProtocol.removeAwarenessStates(this.awareness, [this.doc.clientID], 'close')
    } catch {}
    const socket = this.socket
    this.socket = null
    // The leaving awareness message goes out before the socket closes.
    this.sendQueue.finally(() => socket?.close())
    this.doc.off('update', this.onDocUpdate)
    this.awareness.off('update', this.onAwarenessUpdate)
    this.awareness.destroy()
    this.doc.destroy()
  }

  setStatus(status) {
    if (this.status === status) return
    this.status = status
    this.callbacks.onStatus?.(status)
  }

  /// The members here now, this one included, from awareness.
  peers() {
    const list = []
    for (const [clientID, state] of this.awareness.getStates()) {
      if (!state?.user) continue
      list.push({ clientID, name: state.user.name, color: state.user.color, self: clientID === this.doc.clientID })
    }
    return list.sort((a, b) => a.clientID - b.clientID)
  }

  /// The one member who applies a change that reached everyone at once from
  /// outside the room (a chat's edit through iCloud), so it is applied once.
  isLeader() {
    const ids = Array.from(this.awareness.getStates().keys())
    return ids.length === 0 || Math.min(...ids) === this.doc.clientID
  }

  hasOthers() {
    return this.peers().some((peer) => !peer.self)
  }

  /// The seeder has filled `doc`: the room is live.
  ready() {
    if (this.synced) return
    this.synced = true
    this.sendControl({ t: 'synced' })
    // What the seeder wrote before it was synced goes out now.
    const encoder = encoding.createEncoder()
    syncProtocol.writeUpdate(encoder, Y.encodeStateAsUpdate(this.doc))
    this.sendMessage(LiveMessage.sync, encoding.toUint8Array(encoder))
    this.setStatus('live')
  }

  /// A body this member's host saved, told to the room, so an iCloud copy of
  /// it coming back is known as the room's own.
  noteSaved(markdown) {
    const fingerprint = bodyFingerprint(markdown)
    this.rememberText(markdown)
    this.rememberSaved(fingerprint)
    this.sendMessage(LiveMessage.saved, textEncoder.encode(fingerprint))
  }

  isSavedByRoom(markdown) {
    return this.savedFingerprints.has(bodyFingerprint(markdown))
  }

  /// A body whose words this member knows (one its host saved or handed it),
  /// kept as the base a change from outside the room is merged against.
  rememberText(markdown) {
    const text = String(markdown ?? '')
    const fingerprint = bodyFingerprint(text)
    this.knownTexts.delete(fingerprint)
    this.knownTexts.set(fingerprint, text)
    while (this.knownTexts.size > 16) this.knownTexts.delete(this.knownTexts.keys().next().value)
  }

  /// The newest body the room saved whose words this member knows, or null.
  latestKnownSaved() {
    let latest = null
    let latestAt = -1
    for (const [fingerprint, text] of this.knownTexts) {
      const at = this.savedFingerprints.get(fingerprint)
      if (at != null && at >= latestAt) {
        latest = text
        latestAt = at
      }
    }
    return latest
  }

  rememberSaved(fingerprint) {
    this.savedFingerprints.delete(fingerprint)
    this.savedFingerprints.set(fingerprint, Date.now())
    while (this.savedFingerprints.size > 256) this.savedFingerprints.delete(this.savedFingerprints.keys().next().value)
  }

  sendControl(message) {
    const socket = this.socket
    if (socket?.readyState === 1) socket.send(JSON.stringify(message))
  }

  sendMessage(type, payload) {
    const socket = this.socket
    if (!socket) return
    const plaintext = new Uint8Array(payload.length + 1)
    plaintext[0] = type
    plaintext.set(payload, 1)
    // Sealing is asynchronous; the queue keeps the frames in the order made.
    this.sendQueue = this.sendQueue.then(async () => {
      const frame = await seal(this.key, plaintext, this.subtle)
      if (socket.readyState === 1) socket.send(frame)
    }).catch(() => {})
  }

  requestState() {
    const encoder = encoding.createEncoder()
    syncProtocol.writeSyncStep1(encoder, this.doc)
    this.sendMessage(LiveMessage.sync, encoding.toUint8Array(encoder))
    clearTimeout(this.syncTimer)
    // An answer lost on the way is asked for again.
    this.syncTimer = setTimeout(() => {
      if (!this.synced && this.socket) this.requestState()
    }, 4000)
  }

  async receive(data) {
    if (typeof data === 'string') {
      let message
      try {
        message = JSON.parse(data)
      } catch {
        return
      }
      this.receiveControl(message)
      return
    }
    const plaintext = await open(this.key, data, this.subtle)
    if (!plaintext || plaintext.length < 1 || this.closed) return
    const body = plaintext.subarray(1)
    switch (plaintext[0]) {
      case LiveMessage.sync: {
        const decoder = decoding.createDecoder(body)
        const encoder = encoding.createEncoder()
        const kind = syncProtocol.readSyncMessage(decoder, encoder, this.doc, remoteOrigin)
        // A member not yet synced has nothing to answer with.
        if (this.synced && encoding.length(encoder) > 0) this.sendMessage(LiveMessage.sync, encoding.toUint8Array(encoder))
        if (!this.synced && this.waitingForState && kind === syncProtocol.messageYjsSyncStep2) this.finishSync()
        break
      }
      case LiveMessage.awareness:
        awarenessProtocol.applyAwarenessUpdate(this.awareness, body, remoteOrigin)
        break
      case LiveMessage.saved:
        this.rememberSaved(textDecoder.decode(body))
        break
      default:
        break
    }
  }

  receiveControl(message) {
    switch (message?.t) {
      case 'hello': {
        this.retry = 0
        const restarted = this.epoch != null && message.epoch !== this.epoch
        this.epoch = message.epoch
        if (restarted) {
          // The room emptied and began again from the saved page while this
          // member was away: its document is not the room's any more, and
          // merging the two would write the page twice. What it wrote away
          // was saved by its host and comes back through iCloud.
          this.synced = false
          this.callbacks.onRestart?.()
          this.restart()
          return
        }
        this.sendAwareness()
        if (this.synced) {
          // Back after a drop in the same room: catch up both ways.
          this.sendControl({ t: 'synced' })
          if (!message.seed) this.requestState()
          const encoder = encoding.createEncoder()
          syncProtocol.writeUpdate(encoder, Y.encodeStateAsUpdate(this.doc))
          this.sendMessage(LiveMessage.sync, encoding.toUint8Array(encoder))
          this.setStatus('live')
        } else if (message.seed) {
          this.callbacks.onSeed?.()
        } else {
          this.waitingForState = true
          this.requestState()
        }
        break
      }
      case 'joined':
        // A newcomer learns who is here without waiting for the next renewal.
        this.sendAwareness()
        break
      case 'seed':
        // Everyone synced left before this member's state arrived.
        if (!this.synced) {
          this.waitingForState = false
          clearTimeout(this.syncTimer)
          this.callbacks.onSeed?.()
        }
        break
      default:
        break
    }
  }

  /// Starts this member again in a new room epoch with an empty document.
  restart() {
    this.doc.off('update', this.onDocUpdate)
    this.awareness.off('update', this.onAwarenessUpdate)
    this.awareness.destroy()
    this.doc.destroy()
    this.doc = new Y.Doc()
    this.fragment = this.doc.getXmlFragment('prosemirror')
    this.awareness = new awarenessProtocol.Awareness(this.doc)
    this.awareness.setLocalStateField('user', { name: this.user.name, color: this.user.color })
    this.doc.on('update', this.onDocUpdate)
    this.awareness.on('update', this.onAwarenessUpdate)
    this.epoch = null
    this.synced = false
    const socket = this.socket
    this.socket = null
    socket?.close()
    this.retry = 0
    this.connect()
  }

  finishSync() {
    this.waitingForState = false
    clearTimeout(this.syncTimer)
    this.synced = true
    this.sendControl({ t: 'synced' })
    this.setStatus('live')
    this.callbacks.onSynced?.()
  }

  sendAwareness() {
    this.sendMessage(LiveMessage.awareness, awarenessProtocol.encodeAwarenessUpdate(this.awareness, [this.doc.clientID]))
  }
}
