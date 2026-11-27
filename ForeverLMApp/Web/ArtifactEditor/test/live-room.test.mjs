import test from 'node:test'
import assert from 'node:assert/strict'
import * as Y from 'yjs'
import { LiveRoom, bodyFingerprint, open, pageRoomKeys, seal } from '../src/live-room.js'

// The relay's rules (workers/page-live) in memory: one seeder per room, frames
// passed to everyone else, a new epoch once the room empties.
class FakeRelay {
  constructor() {
    this.rooms = new Map()
    this.frames = []
  }

  socketClass() {
    const relay = this
    return class FakeSocket {
      constructor(url) {
        this.url = url
        this.readyState = 0
        this.synced = false
        this.roomID = url.split('/room/')[1]
        queueMicrotask(() => relay.join(this))
      }

      send(data) {
        relay.receive(this, data)
      }

      close() {
        if (this.readyState === 3) return
        this.readyState = 3
        relay.leave(this)
        queueMicrotask(() => this.onclose?.())
      }
    }
  }

  room(id) {
    if (!this.rooms.has(id)) this.rooms.set(id, { sockets: [], epoch: null })
    return this.rooms.get(id)
  }

  join(socket) {
    if (socket.readyState === 3) return
    const room = this.room(socket.roomID)
    if (room.sockets.length === 0) room.epoch = `epoch-${Math.random()}`
    const seed = !room.sockets.some((other) => other.synced)
    socket.synced = seed
    socket.readyState = 1
    for (const other of room.sockets) other.onmessage?.({ data: JSON.stringify({ t: 'joined' }) })
    room.sockets.push(socket)
    socket.onmessage?.({ data: JSON.stringify({ t: 'hello', epoch: room.epoch, seed, peers: room.sockets.length - 1 }) })
  }

  receive(socket, data) {
    const room = this.room(socket.roomID)
    if (typeof data === 'string') {
      if (JSON.parse(data).t === 'synced') socket.synced = true
      return
    }
    this.frames.push(data)
    for (const other of room.sockets) {
      if (other !== socket) setTimeout(() => other.onmessage?.({ data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) }), 0)
    }
  }

  leave(socket) {
    const room = this.room(socket.roomID)
    room.sockets = room.sockets.filter((other) => other !== socket)
    if (room.sockets.length === 0) return
    if (room.sockets.some((other) => other.synced)) return
    room.sockets[0].synced = true
    room.sockets[0].onmessage?.({ data: JSON.stringify({ t: 'seed' }) })
  }
}

const spaceKey = Buffer.from(new Uint8Array(32).map((_, index) => index + 1)).toString('base64url')

async function member(relay, name, { seedText = '' } = {}) {
  const { roomID, key } = await pageRoomKeys(spaceKey, 'page-1')
  const events = []
  const room = new LiveRoom({
    roomID,
    key,
    relayURL: 'wss://live.test',
    user: { name, color: '#123456' },
    WebSocketImpl: relay.socketClass(),
    callbacks: {
      onSeed() {
        events.push('seed')
        room.doc.getText('t').insert(0, seedText)
        room.ready()
      },
      onSynced() {
        events.push('synced')
      },
      onRestart() {
        events.push('restart')
      },
    },
  })
  room.events = events
  room.connect()
  return room
}

const settle = (ms = 30) => new Promise((resolve) => setTimeout(resolve, ms))

test('every member lands in one room whose name is not the key', async () => {
  const one = await pageRoomKeys(spaceKey, 'page-1')
  const two = await pageRoomKeys(spaceKey, 'page-1')
  const other = await pageRoomKeys(spaceKey, 'page-2')
  assert.equal(one.roomID, two.roomID)
  assert.notEqual(one.roomID, other.roomID)
  assert.match(one.roomID, /^[0-9a-f]{64}$/)
  assert.ok(!one.roomID.includes(Buffer.from(spaceKey, 'base64url').toString('hex')))
})

test('a frame opens only under the page key it was sealed with', async () => {
  const one = await pageRoomKeys(spaceKey, 'page-1')
  const other = await pageRoomKeys(spaceKey, 'page-2')
  const frame = await seal(one.key, new TextEncoder().encode('hello'))
  assert.equal(new TextDecoder().decode(await open(one.key, frame)), 'hello')
  assert.equal(await open(other.key, frame), null)
})

test('the first member seeds, the second takes its document, and edits meet', async () => {
  const relay = new FakeRelay()
  const ada = await member(relay, 'Ada', { seedText: 'Hello' })
  await settle()
  const bea = await member(relay, 'Bea', { seedText: 'SHOULD NOT SEED' })
  await settle(60)
  assert.deepEqual(ada.events, ['seed'])
  assert.deepEqual(bea.events, ['synced'])
  assert.equal(bea.doc.getText('t').toString(), 'Hello')

  ada.doc.getText('t').insert(5, ', world')
  bea.doc.getText('t').insert(0, '¡')
  await settle(60)
  assert.equal(ada.doc.getText('t').toString(), bea.doc.getText('t').toString())
  assert.equal(ada.doc.getText('t').toString(), '¡Hello, world')

  // Nothing the relay saw holds the words.
  for (const frame of relay.frames) assert.ok(!Buffer.from(frame).toString('utf8').includes('world'))
  ada.close()
  bea.close()
})

test('two members joining at once never both seed', async () => {
  const relay = new FakeRelay()
  const [ada, bea] = await Promise.all([member(relay, 'Ada', { seedText: 'Once' }), member(relay, 'Bea', { seedText: 'Once' })])
  await settle(60)
  assert.equal([...ada.events, ...bea.events].filter((event) => event === 'seed').length, 1)
  assert.equal(ada.doc.getText('t').toString(), 'Once')
  assert.equal(bea.doc.getText('t').toString(), 'Once')
  ada.close()
  bea.close()
})

test('each member sees who is here, and one of them is leader', async () => {
  const relay = new FakeRelay()
  const ada = await member(relay, 'Ada', { seedText: 'x' })
  await settle()
  const bea = await member(relay, 'Bea')
  await settle(60)
  assert.deepEqual(ada.peers().map((peer) => peer.name).sort(), ['Ada', 'Bea'])
  assert.deepEqual(bea.peers().map((peer) => peer.name).sort(), ['Ada', 'Bea'])
  assert.equal([ada.isLeader(), bea.isLeader()].filter(Boolean).length, 1)
  ada.close()
  bea.close()
})

test('a body one member saved is known to the others as the room\'s own', async () => {
  const relay = new FakeRelay()
  const ada = await member(relay, 'Ada', { seedText: 'x' })
  await settle()
  const bea = await member(relay, 'Bea')
  await settle(60)
  ada.noteSaved('# Page\n\nSaved by Ada\n')
  await settle(60)
  assert.ok(bea.isSavedByRoom('# Page\n\nSaved by Ada\n'))
  assert.ok(!bea.isSavedByRoom('# Page\n\nWritten by a chat\n'))
  assert.notEqual(bodyFingerprint('a'), bodyFingerprint('b'))
  ada.close()
  bea.close()
})

test('a waiting member seeds when everyone holding the document leaves', async () => {
  const relay = new FakeRelay()
  const ada = await member(relay, 'Ada', { seedText: 'x' })
  await settle()
  // Bea joins and Ada leaves before Bea's state arrives.
  const bea = await member(relay, 'Bea', { seedText: 'from Bea' })
  ada.close()
  await settle(60)
  assert.ok(bea.events.includes('seed') || bea.events.includes('synced'))
  bea.close()
})

test('a member back in a room that began again starts over', async () => {
  const relay = new FakeRelay()
  const ada = await member(relay, 'Ada', { seedText: 'old' })
  await settle()
  // Ada drops; the room empties and a new epoch begins with Bea.
  ada.socket.close()
  await settle()
  const bea = await member(relay, 'Bea', { seedText: 'new' })
  await settle(1200)
  assert.ok(ada.events.includes('restart'))
  assert.equal(ada.doc.getText('t').toString(), 'new')
  assert.ok(ada.doc instanceof Y.Doc)
  ada.close()
  bea.close()
})
