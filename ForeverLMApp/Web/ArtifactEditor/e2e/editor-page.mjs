// What the browser tests do to the editor: open it as a host does, hand it a
// page, put the caret somewhere, and read what it stored and told the host.
// Typing goes through Playwright's keyboard, so input rules, key handlers and
// the browser's own editing all run as they do for a writer.
import { pathToFileURL } from 'node:url'

export const hostURL = pathToFileURL(new URL('./host.html', import.meta.url).pathname).href
export const every = { pages: true, images: true, imageGeneration: true, visualize: true, files: true, sources: true }

export async function openEditor(page, markdown = '', { key = 'page-1', features = every } = {}) {
  const errors = []
  page.on('pageerror', (error) => errors.push(String(error?.stack ?? error)))
  await page.goto(hostURL)
  await page.evaluate((text) => window.foreverLMArtifactEditor.create(text, 15), markdown)
  await page.waitForFunction(() => window.hostMessages.some((message) => message.type === 'ready'))
  await page.evaluate(([name, slash]) => {
    window.foreverLMArtifactEditor.setSlashFeatures(slash)
    window.foreverLMArtifactEditor.setMarkdown(window.foreverLMArtifactEditor.serializedMarkdown(), { key: name, folds: '[]' })
  }, [key, features])
  await settle(page)
  return errors
}

/// Hand the editor a page, as the host does when it opens one.
export async function load(page, markdown, key) {
  await page.evaluate(([text, name]) => window.foreverLMArtifactEditor.setMarkdown(text, { key: name, folds: '[]' }), [markdown, key])
  await settle(page)
}

/// Two frames and a beat: long enough for the editor's own frame work.
export async function settle(page, ms = 50) {
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  if (ms) await page.waitForTimeout(ms)
}

export const stored = (page) => page.evaluate(() => window.foreverLMArtifactEditor.serializedMarkdown())

export const text = (page) => page.evaluate(() => window.__editorTest.view().state.doc.textContent)

export const messages = (page, type) => page.evaluate((kind) => window.hostMessages.filter((message) => !kind || message.type === kind), type)

export const lastReport = async (page) => (await messages(page, 'markdownChanged')).at(-1)

export const clearMessages = (page) => page.evaluate(() => { window.hostMessages.length = 0 })

/// The page's top-level blocks as kind names, `empty` for an empty paragraph.
export const blocks = (page) => page.evaluate(() => {
  const names = []
  window.__editorTest.view().state.doc.forEach((node) => names.push(node.type.name === 'paragraph' && node.childCount === 0 ? 'empty' : node.type.name))
  return names
})

/// Put the caret in the first text block that starts with `prefix`: at its end,
/// or `offset` characters in. The editor takes focus as a click would give it.
export async function caretIn(page, prefix, offset = null) {
  const found = await page.evaluate(([start, at]) => {
    const view = window.__editorTest.view()
    let position = null
    view.state.doc.descendants((node, pos) => {
      if (position == null && node.isTextblock && node.textContent.startsWith(start)) {
        position = pos + 1 + (at ?? node.content.size)
      }
    })
    if (position == null) return false
    const Selection = view.state.selection.constructor
    view.focus()
    view.dispatch(view.state.tr.setSelection(Selection.create(view.state.doc, position)).scrollIntoView())
    return true
  }, [prefix, offset])
  if (!found) throw new Error(`No block starts with ${JSON.stringify(prefix)}`)
  await settle(page, 0)
}

/// Select the words of the first text block that starts with `prefix`.
export async function selectBlock(page, prefix) {
  await page.evaluate((start) => {
    const view = window.__editorTest.view()
    let range = null
    view.state.doc.descendants((node, pos) => {
      if (!range && node.isTextblock && node.textContent.startsWith(start)) range = [pos + 1, pos + 1 + node.content.size]
    })
    const Selection = view.state.selection.constructor
    view.focus()
    view.dispatch(view.state.tr.setSelection(Selection.create(view.state.doc, range[0], range[1])))
  }, prefix)
  await settle(page, 0)
}

/// A paste of the given clipboard types, as the browser delivers one.
export async function paste(page, data, files = []) {
  await page.evaluate(([types, pictures]) => {
    const transfer = new DataTransfer()
    for (const [type, value] of Object.entries(types)) transfer.setData(type, value)
    for (const picture of pictures) {
      const bytes = Uint8Array.from(atob(picture.base64), (character) => character.charCodeAt(0))
      transfer.items.add(new File([bytes], picture.name, { type: picture.type }))
    }
    window.__editorTest.view().dom.dispatchEvent(new ClipboardEvent('paste', { clipboardData: transfer, bubbles: true, cancelable: true }))
  }, [data, files])
  await settle(page)
}

export const onePixelPNG = {
  name: 'shot.png',
  type: 'image/png',
  base64: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
}
