// A passage's sources are one link over its words (artifact-editor.js,
// "grounding"). A quote with line breaks was attached one printed line at a
// time: Milkdown's hard-break plugin takes the marks off a line break whenever
// a transaction begins by adding a mark, so the link stopped at every break
// and the page stored `[line](foreverlm://grounding/a)\` + newline +
// `[next line](foreverlm://grounding/a)`. That drew as a run of separate
// passages, sent the model the address once a line, and would cite the source
// once a line in a Google Doc.
//
// This remark pass reads links with the same grounding address that nothing
// but line breaks and spaces part as the one passage they are, so a page
// written that way opens whole and is saved whole the next time it changes.
// Pure mdast, so a test runs it without an editor
// (test/joined-grounding.test.mjs).

const groundingPrefixes = ['foreverlm://grounding/', 'https://foreverlm.invalid/grounding/']

function isGrounding(node) {
  return node?.type === 'link' && groundingPrefixes.some((prefix) => String(node.url ?? '').toLowerCase().startsWith(prefix))
}

/// Nothing a reader sees between two links: a line break or white space.
function isGap(node) {
  return node?.type === 'break' || (node?.type === 'text' && /^\s*$/.test(node.value ?? ''))
}

function sameLink(left, right) {
  return left.url === right.url && (left.title ?? null) === (right.title ?? null)
}

/// Join, in every node's children, a grounding link with the next one of the
/// same address when only gaps stand between them; the gaps go inside.
export function joinGroundingLinks(node) {
  if (!Array.isArray(node?.children)) return
  const children = []
  for (let index = 0; index < node.children.length; index += 1) {
    const child = node.children[index]
    const previous = children[children.length - 1]
    if (isGrounding(child) && isGrounding(previous) && sameLink(previous, child)) {
      previous.children.push(...child.children)
      continue
    }
    if (isGap(child) && isGrounding(previous)) {
      // A gap joins the link before it only when the same link follows it.
      let next = index + 1
      while (next < node.children.length && isGap(node.children[next])) next += 1
      const following = node.children[next]
      if (isGrounding(following) && sameLink(previous, following)) {
        previous.children.push(...node.children.slice(index, next), ...following.children)
        index = next
        continue
      }
    }
    children.push(child)
  }
  node.children = children
  for (const child of node.children) joinGroundingLinks(child)
}

/// The remark plugin: `$remark('…', () => remarkJoinedGrounding)`.
export function remarkJoinedGrounding() {
  return (tree) => {
    joinGroundingLinks(tree)
  }
}
