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

// ─── What the edit changes ──────────────────────────────────────────────────
// An edit written into the page is marked against the passage it replaced:
// new words washed, removed ones struck through, the way a tracked change
// reads. Words are compared as the page shows them (a link's words, not its
// address), so keeping a citation is no change and joining lines that a PDF
// broke is none either.

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

/// What a tracked change marks once an edit is written into the page: the
/// indices of the new words that are new, and the words taken out by the index
/// of the word they stood before (`after.length` for the end). `wordLevel` is
/// false when the edit keeps less than `minimumKept` of its words from the
/// passage, or either side has none: a rewrite reads better washed whole, with
/// the passage it replaced struck through, than covered in marks.
export function reviewWordMarks(before, after, { minimumKept = 0.35 } = {}) {
  if (before.length === 0 || after.length === 0) return { wordLevel: false, added: [], removed: new Map() }
  const { kept, removed } = wordChanges(before, after)
  const keptCount = kept.filter(Boolean).length
  if (keptCount / after.length < minimumKept) return { wordLevel: false, added: [], removed: new Map() }
  const added = []
  kept.forEach((wasKept, index) => { if (!wasKept) added.push(index) })
  return { wordLevel: true, added, removed }
}
