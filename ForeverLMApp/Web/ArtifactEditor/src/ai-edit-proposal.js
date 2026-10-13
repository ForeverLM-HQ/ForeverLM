// Edit with AI: what the model reads of the page, and the proposal as the
// writer reads it before taking it (artifact-editor.js, "AI edits"). Pure
// text and DOM work, so a test can run it without an editor
// (test/ai-edit-proposal.test.mjs).

// ─── The page's own addresses ───────────────────────────────────────────────
// A passage's sources, a picture, a link to another page: each is a long id
// in a `foreverlm://` address. The model has no use for the ids and can only
// copy them wrong (a quote grounded line by line carried the same 64-character
// address once per printed line), so it reads each address as a short
// stand-in, `foreverlm://grounding/1`, and the editor writes the real address
// back into the answer. The app writes what it knows; the model only keeps a
// link where it stands.

const productAddress = /foreverlm:\/\/([a-z]+)\/([^\s()<>[\]"'`]+)/gi
const standInAddress = /^(?:foreverlm:\/\/|https:\/\/foreverlm\.invalid\/)[a-z]+\/\d+$/i

/// One request's stand-ins, both ways.
export function newAddressAliases() {
  return { byAddress: new Map(), byAlias: new Map() }
}

/// `text` with every product address replaced by its stand-in, numbered in
/// the order first met. The same address always reads as the same stand-in,
/// across the passage, its context and the page's instructions.
export function aliasedAddresses(text, aliases) {
  return String(text ?? '').replace(productAddress, (address, kind) => {
    let alias = aliases.byAddress.get(address)
    if (!alias) {
      alias = `foreverlm://${kind.toLowerCase()}/${aliases.byAddress.size + 1}`
      aliases.byAddress.set(address, alias)
      aliases.byAlias.set(alias, address)
    }
    return alias
  })
}

/// The model's answer with each stand-in it was given, as a link's or a
/// picture's target, turned back into the address it stands for. One it was
/// not given is one it made up and is left as it is: `isAddressStandIn` tells
/// the editor to drop the link it is on and keep the words.
export function restoredAddresses(text, aliases) {
  return String(text ?? '').replace(/(\]\(\s*)(foreverlm:\/\/[a-z]+\/\d+)(?=[\s)])/gi, (whole, opening, alias) => {
    const address = aliases.byAlias.get(alias) ?? aliases.byAlias.get(alias.toLowerCase())
    return address ? opening + address : whole
  })
}

/// Whether a link or picture address is still a stand-in after restoring:
/// one the model made up, in the stored or the editor's form.
export function isAddressStandIn(address) {
  return standInAddress.test(String(address ?? ''))
}

// ─── What the proposal changes ──────────────────────────────────────────────
// The proposal is drawn as the page will draw it, and the words it changes
// are marked against the passage: new words washed, removed ones struck
// through, the way a tracked change reads. Words are compared as the page
// shows them (a link's words, not its address), so keeping a citation is no
// change and joining lines that a PDF broke is none either.

/// Which words of `after` the edit kept from `before`, and the words it took
/// out, by the index of the word in `after` they stood before (`after.length`
/// for the end). The longest run of kept words wins; beyond `limit` cells the
/// changed middle is not aligned and reads as replaced whole.
export function wordChanges(before, after, { limit = 250_000 } = {}) {
  const kept = new Array(after.length).fill(false)
  const removed = new Map()
  const remove = (at, word) => {
    if (!removed.has(at)) removed.set(at, [])
    removed.get(at).push(word)
  }
  let start = 0
  while (start < before.length && start < after.length && before[start] === after[start]) {
    kept[start] = true
    start += 1
  }
  let endBefore = before.length
  let endAfter = after.length
  while (endBefore > start && endAfter > start && before[endBefore - 1] === after[endAfter - 1]) {
    endBefore -= 1
    endAfter -= 1
    kept[endAfter] = true
  }
  const rows = endBefore - start
  const columns = endAfter - start
  if (rows * columns > limit) {
    for (let index = start; index < endBefore; index += 1) remove(start, before[index])
    return { kept, removed }
  }
  // Longest common run of words, from the end, so a forward walk can follow it.
  const table = Array.from({ length: rows + 1 }, () => new Uint32Array(columns + 1))
  for (let row = rows - 1; row >= 0; row -= 1) {
    for (let column = columns - 1; column >= 0; column -= 1) {
      table[row][column] = before[start + row] === after[start + column]
        ? table[row + 1][column + 1] + 1
        : Math.max(table[row + 1][column], table[row][column + 1])
    }
  }
  let row = 0
  let column = 0
  while (row < rows && column < columns) {
    if (before[start + row] === after[start + column]) {
      kept[start + column] = true
      row += 1
      column += 1
    } else if (table[row + 1][column] >= table[row][column + 1]) {
      remove(start + column, before[start + row])
      row += 1
    } else {
      column += 1
    }
  }
  for (; row < rows; row += 1) remove(start + column, before[start + row])
  return { kept, removed }
}

/// The words of a drawn fragment in reading order, each with the text node it
/// is in and its place there. A word split by formatting is two words; it is
/// split the same way on both sides of a comparison.
export function wordsOfDOM(root) {
  const words = []
  const walker = root.ownerDocument.createTreeWalker(root, 4 /* NodeFilter.SHOW_TEXT */)
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    for (const match of node.data.matchAll(/\S+/g)) {
      words.push({ node, start: match.index, end: match.index + match[0].length, text: match[0] })
    }
  }
  return words
}

/// Mark in `root` what the proposal changes against `before` (the passage's
/// words): `<ins>` around new words, a `<del>` holding the words taken out
/// where they stood. Nothing is marked when the proposal keeps less than
/// `minimumKept` of its words from the passage: a rewrite reads better
/// clean than covered in marks. Says what it found.
export function markedWordChanges(root, before, { minimumKept = 0.35 } = {}) {
  const words = wordsOfDOM(root)
  const { kept, removed } = wordChanges(before, words.map((word) => word.text))
  const keptCount = kept.filter(Boolean).length
  const removedCount = [...removed.values()].reduce((sum, list) => sum + list.length, 0)
  const added = words.length - keptCount
  const summary = { added, removed: removedCount, kept: keptCount, marked: false }
  if (added === 0 && removedCount === 0) return summary
  if (words.length === 0 || keptCount / words.length < minimumKept) return summary

  // Runs: a stretch of new words in one text node, and what was taken out
  // before it, worked from the last to the first so the places of earlier
  // words in a node stay where they were measured.
  const document = root.ownerDocument
  const runs = []
  for (let index = 0; index < words.length; index += 1) {
    const word = words[index]
    const taken = removed.get(index)
    const last = runs[runs.length - 1]
    if (!kept[index] && last && last.inserted && last.node === word.node && last.lastIndex === index - 1 && !taken) {
      last.end = word.end
      last.lastIndex = index
      continue
    }
    runs.push({ node: word.node, start: word.start, end: word.end, inserted: !kept[index], lastIndex: index, taken })
  }
  const deletion = (list) => {
    const element = document.createElement('del')
    element.textContent = list.join(' ')
    return element
  }
  const tail = removed.get(words.length)
  if (tail && words.length) {
    const last = words[words.length - 1]
    const range = document.createRange()
    range.setStart(last.node, last.end)
    range.collapse(true)
    range.insertNode(deletion(tail))
    range.insertNode(document.createTextNode(' '))
  }
  for (let index = runs.length - 1; index >= 0; index -= 1) {
    const run = runs[index]
    const range = document.createRange()
    if (run.inserted) {
      range.setStart(run.node, run.start)
      range.setEnd(run.node, run.end)
      range.surroundContents(document.createElement('ins'))
    }
    if (run.taken) {
      range.setStart(run.node, run.start)
      range.collapse(true)
      range.insertNode(document.createTextNode(' '))
      range.insertNode(deletion(run.taken))
    }
  }
  summary.marked = true
  return summary
}
