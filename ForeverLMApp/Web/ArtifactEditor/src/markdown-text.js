// How a run of text is written to Markdown (remark-stringify's `text`
// handler; artifact-editor.js puts it in `remarkStringifyOptionsCtx`).
//
// Milkdown's own handler (@milkdown/core, `remarkHandlers.text`) writes a run
// that ends in white space and holds no `*`, `_` or `\` exactly as it is, so
// the space before a bold or italic word is not written as `&#x20;`. That also
// skipped every escape in the run: a paragraph that begins "- a point" or
// "1. First, " and has bold or italic later was written without its escape and
// read back as a list (found by e2e/fuzz.spec.mjs). Here the run's words are
// escaped as remark escapes any text, and only the white space that ends the
// run is written as it is. Pure, so test/markdown-text.test.mjs runs it with
// remark's own writer.

export function textWithItsEscapes(node, _parent, state, info) {
  const value = String(node.value ?? '')
  const words = value.replace(/\s+$/, '')
  if (words.length === value.length || /[*_\\]/.test(value)) return state.safe(value, { ...info, encode: [] })
  if (!words) return value
  const space = value.slice(words.length)
  return state.safe(words, { ...info, after: space[0], encode: [] }) + space
}
