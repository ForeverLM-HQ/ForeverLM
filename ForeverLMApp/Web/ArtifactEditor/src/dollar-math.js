// Dollar signs on a Page: money or math.
//
// remark-math reads any two dollar signs in a paragraph as inline math, so
// "a few $20 copies … the $1.8 million" drew everything between them as one
// italic TeX run. A page holds prices far more often than formulas, so a span
// between single dollar signs is math only by Pandoc's rule: the opening `$`
// has a non-space right after it, the closing `$` a non-space right before it
// and no digit right after it (`$20 and $30` is money, `$x^2$` is math). A
// span between double dollar signs (`$$x$$`) is always math, and two a side is
// what typing math takes (`artifact-editor.js`, "Typing math"), so a typed
// price is never caught (product owner, 2026-10-12: "don't do this when i do
// one dollar sign").
//
// The rule is applied where Markdown is read (`moneyAwareMathText`), so every
// way text reaches a page (opening it, pasting, a model writing it) reads the
// same, and where it is written (`moneySafeInlineMath`), so math the page
// itself saves always reads back as math.

const dollar = 36

/// Whether a span between single dollar signs is money rather than math, given
/// the character after the opening `$`, the one before the closing `$` and the
/// one after it ('' at the end of the text).
export function singleDollarSpanIsMoney(afterOpen, beforeClose, afterClose) {
  return isBlank(afterOpen) || isBlank(beforeClose) || /^[0-9]$/.test(afterClose ?? '')
}

function isBlank(character) {
  return typeof character === 'string' && character !== '' && /^\s$/u.test(character)
}

/// micromark's character code as a one-character string: line endings, tabs
/// and virtual spaces (negative codes) are blank, the end of the text is ''.
function characterOfCode(code) {
  if (code === null || code === undefined) return ''
  return code < 0 ? ' ' : String.fromCodePoint(code)
}

/// micromark-extension-math's text construct, refusing a single-dollar span
/// that reads as money. The span's own tokenizer runs unchanged; this records
/// the codes it consumes and, where it would succeed, looks at the code after
/// the closing `$` as well. A refused span leaves the `$` as text and the words
/// after it are read as any other Markdown (their emphasis, links and all).
export function moneyAwareMathText(construct) {
  return {
    ...construct,
    moneyAware: true,
    tokenize(effects, ok, nok) {
      const consumed = []
      const recording = {
        ...effects,
        consume(code) {
          consumed.push(code)
          return effects.consume(code)
        },
      }
      const decide = (code) => {
        const openingLength = consumed.findIndex((consumedCode) => consumedCode !== dollar)
        if (openingLength !== 1) return ok(code)
        const money = singleDollarSpanIsMoney(
          characterOfCode(consumed[1]),
          characterOfCode(consumed[consumed.length - 2]),
          characterOfCode(code),
        )
        return money ? nok(code) : ok(code)
      }
      return construct.tokenize.call(this, recording, decide, nok)
    },
  }
}

/// mdast-util-math's inline math writer, made to write two dollar signs a side
/// wherever one a side would read back as money: math that starts or ends with
/// a space, or that is followed straight away by a digit.
export function moneySafeInlineMath(write) {
  const written = function (node, parent, state, info) {
    const markdown = write(node, parent, state, info)
    if (!/^\$[^$]/.test(markdown) || !/[^$]\$$/.test(markdown)) return markdown
    const inner = markdown.slice(1, -1)
    if (!singleDollarSpanIsMoney(inner[0], inner[inner.length - 1], info?.after ?? '')) return markdown
    // The shortest run of dollar signs, two or more, that the math does not
    // hold on its own, as the writer itself picks the fence.
    const value = String(node.value ?? '')
    let size = 2
    while (new RegExp('(^|[^$])' + '\\$'.repeat(size) + '([^$]|$)').test(value)) size += 1
    const fence = '$'.repeat(size)
    return `${fence}${inner}${fence}`
  }
  if (write.peek) written.peek = write.peek
  return written
}

/// A remark plugin, used after remark-math: its `$` construct and its inline
/// math writer, swapped for the ones above.
export function remarkMoneyIsNotMath() {
  const data = this.data()
  for (const extension of data.micromarkExtensions ?? []) {
    const constructs = extension?.text?.[dollar]
    if (!constructs) continue
    const swap = (construct) => (construct?.name === 'mathText' && !construct.moneyAware ? moneyAwareMathText(construct) : construct)
    extension.text[dollar] = Array.isArray(constructs) ? constructs.map(swap) : swap(constructs)
  }
  for (const extension of data.toMarkdownExtensions ?? []) {
    const write = extension?.handlers?.inlineMath
    if (write && !write.moneySafe) {
      extension.handlers.inlineMath = moneySafeInlineMath(write)
      extension.handlers.inlineMath.moneySafe = true
    }
  }
}
