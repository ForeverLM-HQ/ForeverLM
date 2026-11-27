// Live team Pages (docs/teams-design.md, "Live team Pages"): two members'
// editors on one page, in two WebKit pages, joined by a relay that follows
// workers/page-live's rules (one seeder, frames passed on unread, a new epoch
// once the room empties). The relay runs here in the test; each editor's
// WebSocket is a stand-in that reaches it through a Playwright binding.
import { expect, test } from '@playwright/test'
import { caretIn, messages, openEditor, settle, stored, text } from './editor-page.mjs'

const spaceKey = Buffer.from(new Uint8Array(32).map((_, index) => 200 - index)).toString('base64url')

class Relay {
  constructor() {
    this.sockets = new Map()
    this.epoch = null
    this.frames = []
  }

  async attach(page, name) {
    await page.exposeBinding('__relay', async (_source, { op, id, data, text: control }) => {
      if (op === 'open') return this.open(page, id)
      if (op === 'close') return this.close(id)
      if (op === 'text') return this.control(id, control)
      if (op === 'binary') return this.binary(id, data)
    })
    await page.addInitScript(() => {
      let next = 0
      window.__liveSockets = new Map()
      window.WebSocket = class RelaySocket {
        constructor(url) {
          this.url = url
          this.id = `${Math.random()}-${next++}`
          this.readyState = 0
          window.__liveSockets.set(this.id, this)
          window.__relay({ op: 'open', id: this.id })
        }
        send(data) {
          if (typeof data === 'string') window.__relay({ op: 'text', id: this.id, text: data })
          else window.__relay({ op: 'binary', id: this.id, data: Array.from(new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength)) })
        }
        close() {
          if (this.readyState === 3) return
          this.readyState = 3
          window.__relay({ op: 'close', id: this.id })
          setTimeout(() => this.onclose?.(), 0)
        }
      }
      window.__deliver = (id, message) => {
        const socket = window.__liveSockets.get(id)
        if (!socket || socket.readyState === 3) return
        if (message.open) socket.readyState = 1
        const data = message.text ?? new Uint8Array(message.data).buffer
        socket.onmessage?.({ data })
      }
    })
    this[name] = page
  }

  deliver(id, message) {
    const socket = this.sockets.get(id)
    socket?.page.evaluate(([to, body]) => window.__deliver(to, body), [id, message]).catch(() => {})
  }

  open(page, id) {
    if (this.sockets.size === 0) this.epoch = `epoch-${Math.random()}`
    const seed = ![...this.sockets.values()].some((socket) => socket.synced)
    for (const other of this.sockets.keys()) this.deliver(other, { text: JSON.stringify({ t: 'joined' }) })
    this.sockets.set(id, { page, synced: seed })
    this.deliver(id, { open: true, text: JSON.stringify({ t: 'hello', epoch: this.epoch, seed, peers: this.sockets.size - 1 }) })
  }

  control(id, control) {
    if (JSON.parse(control).t === 'synced' && this.sockets.has(id)) this.sockets.get(id).synced = true
  }

  binary(id, data) {
    this.frames.push(Buffer.from(data))
    for (const other of this.sockets.keys()) if (other !== id) this.deliver(other, { data })
  }

  close(id) {
    this.sockets.delete(id)
    if (this.sockets.size === 0) return
    if ([...this.sockets.values()].some((socket) => socket.synced)) return
    const [heir, socket] = this.sockets.entries().next().value
    socket.synced = true
    this.deliver(heir, { text: JSON.stringify({ t: 'seed' }) })
  }
}

async function goLive(page, name, color) {
  await page.evaluate(([key, who, hue]) => window.foreverLMArtifactEditor.setLive({
    spaceKey: key, pageID: 'team-page-1', relayURL: 'wss://live.test', name: who, color: hue,
  }), [spaceKey, name, color])
}

async function twoMembers(browser, markdown) {
  const relay = new Relay()
  const ada = await (await browser.newContext()).newPage()
  const bea = await (await browser.newContext()).newPage()
  await relay.attach(ada, 'ada')
  await relay.attach(bea, 'bea')
  const errors = [...await openEditor(ada, markdown), ...await openEditor(bea, markdown)]
  await goLive(ada, 'Ada Lovelace', '#d9480f')
  await expect.poll(() => relay.sockets.size).toBe(1)
  await settle(ada, 200)
  await goLive(bea, 'Bea Morgan', '#1971c2')
  await expect.poll(() => messages(bea, 'livePeersChanged').then((all) => all.at(-1)?.status)).toBe('live')
  return { relay, ada, bea, errors }
}

test('two members type into one page and each sees the other\'s words', async ({ browser }) => {
  const { relay, ada, bea, errors } = await twoMembers(browser, '# Plan\n\nFirst line.\n')
  await caretIn(ada, 'First line')
  await ada.keyboard.type(' Ada was here.', { delay: 15 })
  await expect.poll(() => text(bea)).toBe('PlanFirst line. Ada was here.')

  await caretIn(bea, 'Plan')
  await bea.keyboard.type(' for Q1', { delay: 15 })
  await expect.poll(() => text(ada)).toBe('Plan for Q1First line. Ada was here.')
  expect(await stored(ada)).toBe(await stored(bea))

  // The relay saw sealed frames only.
  for (const frame of relay.frames) expect(frame.toString('utf8')).not.toContain('Ada was here')
  expect(errors).toEqual([])
})

test('a member sees who else is on the page, with a caret named for them', async ({ browser }) => {
  const { ada, bea } = await twoMembers(browser, '# Plan\n\nFirst line.\n')
  await expect.poll(() => ada.locator('.live-peer').getAttribute('title')).toBe('Bea Morgan')
  await expect.poll(() => bea.locator('.live-peer').getAttribute('title')).toBe('Ada Lovelace')
  await caretIn(bea, 'First line')
  await expect.poll(() => ada.locator('.live-caret-name').first().textContent()).toBe('Bea Morgan')
})

test('undo takes back the writer\'s own words, never a teammate\'s', async ({ browser }) => {
  const { ada, bea } = await twoMembers(browser, '# Plan\n\nLine.\n')
  await caretIn(ada, 'Line')
  await ada.keyboard.type(' Ada', { delay: 15 })
  await expect.poll(() => text(bea)).toBe('PlanLine. Ada')
  await caretIn(bea, 'Plan')
  await bea.keyboard.type(' Bea', { delay: 15 })
  await expect.poll(() => text(ada)).toBe('Plan BeaLine. Ada')
  await ada.waitForTimeout(600)
  await ada.evaluate(() => window.foreverLMArtifactEditor.performHistoryAction('undo'))
  await expect.poll(() => text(bea)).toBe('Plan BeaLine.')
  expect(await text(ada)).toBe('Plan BeaLine.')
})

test('the room\'s own saves coming back through iCloud change nothing, and only one member applies a chat\'s edit', async ({ browser }) => {
  const { ada, bea } = await twoMembers(browser, '# Plan\n\nLine.\n')
  await caretIn(ada, 'Line')
  await ada.keyboard.type(' typed', { delay: 15 })
  await ada.evaluate(() => document.activeElement?.blur())
  await expect.poll(() => messages(ada, 'markdownChanged').then((all) => all.length)).toBeGreaterThan(0)
  const saved = (await messages(ada, 'markdownChanged')).at(-1).markdown
  await expect.poll(() => text(bea)).toBe('PlanLine. typed')

  // Ada's save reaches both Macs a moment later, after Bea typed more.
  await caretIn(bea, 'Plan')
  await bea.keyboard.type('!', { delay: 15 })
  await expect.poll(() => text(ada)).toBe('Plan!Line. typed')
  for (const page of [ada, bea]) await page.evaluate((body) => window.foreverLMArtifactEditor.setMarkdown(body), saved)
  await settle(ada, 300)
  expect(await text(ada)).toBe('Plan!Line. typed')
  expect(await text(bea)).toBe('Plan!Line. typed')

  // A chat's edit arrives on both Macs at once: written once, not twice.
  const chat = '# Plan!\n\nLine. typed\n\nA line from a chat.\n'
  for (const page of [ada, bea]) await page.evaluate((body) => window.foreverLMArtifactEditor.setMarkdown(body), chat)
  await expect.poll(() => text(bea)).toBe('Plan!Line. typedA line from a chat.')
  await settle(ada, 300)
  expect(await text(ada)).toBe('Plan!Line. typedA line from a chat.')
  expect(await text(bea)).toBe('Plan!Line. typedA line from a chat.')
})

test('a chat\'s edit made on an older copy keeps what was typed since', async ({ browser }) => {
  const { ada, bea } = await twoMembers(browser, '# Plan\n\nOne.\n\nTwo.\n')
  await caretIn(ada, 'One')
  await ada.keyboard.type(' typed', { delay: 15 })
  await ada.evaluate(() => document.activeElement?.blur())
  await expect.poll(() => messages(ada, 'markdownChanged').then((all) => all.length)).toBeGreaterThan(0)
  const saved = (await messages(ada, 'markdownChanged')).at(-1).markdown
  for (const page of [ada, bea]) await page.evaluate((body) => window.foreverLMArtifactEditor.setMarkdown(body), saved)
  // Bea types on after that save reached iCloud.
  await caretIn(bea, 'Two')
  await bea.keyboard.type(' later', { delay: 15 })
  await expect.poll(() => text(ada)).toBe('PlanOne. typedTwo. later')
  // A chat edits the saved copy, which has not got Bea's words.
  const chat = saved.replace('# Plan', '# Plan for March')
  for (const page of [ada, bea]) await page.evaluate((body) => window.foreverLMArtifactEditor.setMarkdown(body), chat)
  await expect.poll(() => text(bea)).toBe('Plan for MarchOne. typedTwo. later')
  await settle(ada, 300)
  expect(await text(ada)).toBe('Plan for MarchOne. typedTwo. later')
})

test('a member who joins later is given the page as the room has it', async ({ browser }) => {
  const { ada, bea } = await twoMembers(browser, '# Plan\n\nLine.\n')
  await caretIn(ada, 'Line')
  await ada.keyboard.type(' live words', { delay: 15 })
  await expect.poll(() => text(bea)).toBe('PlanLine. live words')
  // Bea leaves and opens the page again from the older saved copy.
  await bea.evaluate(() => window.foreverLMArtifactEditor.setLive(null))
  await bea.evaluate(() => window.foreverLMArtifactEditor.setMarkdown('# Plan\n\nLine.\n'))
  await goLive(bea, 'Bea Morgan', '#1971c2')
  await expect.poll(() => text(bea)).toBe('PlanLine. live words')
})
