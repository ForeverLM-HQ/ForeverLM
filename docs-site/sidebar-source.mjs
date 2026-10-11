// The sidebar array's source text in .vitepress/config.mjs, read without
// importing the config (importing would require node_modules for the
// `vitepress` dependency). The array is found by its own brackets, not by the
// key that happens to follow it, so removing or reordering other theme keys
// cannot break it. Returns null when there is no `sidebar: [ … ]`.

export function sidebarSource(config) {
  const key = config.indexOf('sidebar:')
  if (key < 0) return null
  const open = config.indexOf('[', key)
  if (open < 0) return null

  let depth = 0
  let quote = null
  for (let i = open; i < config.length; i++) {
    const char = config[i]
    if (quote) {
      if (char === '\\') i++
      else if (char === quote) quote = null
      continue
    }
    if (char === "'" || char === '"' || char === '`') quote = char
    else if (char === '[') depth++
    else if (char === ']' && --depth === 0) return config.slice(open, i + 1)
  }
  return null
}
