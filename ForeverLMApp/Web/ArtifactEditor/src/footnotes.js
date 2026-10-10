// ─── Footnotes: the numbering rule ──────────────────────────────────────────
// A page's footnotes are GFM footnotes in its Markdown: `[^1]` where the note
// is called for, and `[^1]: The note.` at the foot of the page
// (docs/docs-design.md, "Footnotes"). Substack's editor was the model: a
// writer puts a number in the sentence, writes the note at the bottom, and
// never numbers anything by hand.
//
// This file is the pure half of that rule, the part every reader of a page
// agrees on: which note gets which number, in which order the notes stand, and
// what each note's label becomes when the editor writes the page back. It
// knows nothing of ProseMirror, so the website's tests read it as it is.
//
// - A note's **number** is its place in the list of notes.
// - The list is every note that is referenced, in the order of its first
//   reference in the page, then every note nobody references, in the order
//   they stand. A page only gets an unreferenced note from outside the editor
//   (a writer's own Markdown, an MCP client), and the editor keeps it rather
//   than lose its words.
// - A **numeric label** is the writer's number for the note, so the editor
//   rewrites it to the note's number: `[^7]` cited first is written `[^1]`.
//   A **named label** (`[^smith2020]`) is a name someone chose; it stays, and
//   the note still shows its number.

/// Two labels name one note when they match ignoring case and runs of spaces,
/// as GFM matches a reference to its definition.
export function footnoteKey(label) {
  return String(label ?? '').trim().replace(/\s+/g, ' ').toLowerCase()
}

export function isNumericLabel(label) {
  return /^\d+$/.test(String(label ?? ''))
}

/// A label no note of the page has: one past the highest numeric label.
/// `labels` is every label the page has (references and definitions).
export function freshNumericLabel(labels, after = 0) {
  let highest = after
  for (const label of labels) {
    if (isNumericLabel(label)) highest = Math.max(highest, Number(label))
  }
  return String(highest + 1)
}

/// Where each note goes and what it is called.
///
/// `references` are the labels of the page's references in reading order;
/// `definitions` the labels of its definitions in the order they stand. The
/// answer lists the definitions in their new order, each as
/// `{ index, label, number }` (`index` into `definitions`), and `labels` maps a
/// reference's key to `{ label, number }`. A definition whose key another
/// definition already took is not the note its references reach (GFM reads
/// the first); it is kept as an unreferenced note under a number of its own.
export function planFootnotes(references, definitions) {
  const firstDefinition = new Map()
  definitions.forEach((label, index) => {
    const key = footnoteKey(label)
    if (!firstDefinition.has(key)) firstDefinition.set(key, index)
  })
  const order = []
  const placed = new Set()
  for (const label of references) {
    const index = firstDefinition.get(footnoteKey(label))
    if (index == null || placed.has(index)) continue
    placed.add(index)
    order.push(index)
  }
  definitions.forEach((_label, index) => {
    if (!placed.has(index)) order.push(index)
  })
  const notes = order.map((index, position) => {
    const label = definitions[index]
    const number = position + 1
    const duplicate = firstDefinition.get(footnoteKey(label)) !== index
    // A duplicate's label is the number it shows, so it names itself alone.
    return { index, number, label: isNumericLabel(label) || duplicate ? String(number) : label }
  })
  const labels = new Map()
  for (const note of notes) {
    const key = footnoteKey(definitions[note.index])
    if (firstDefinition.get(key) === note.index) labels.set(key, { label: note.label, number: note.number })
  }
  return { notes, labels }
}
