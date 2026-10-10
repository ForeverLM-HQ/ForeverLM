// The notes graph's grammar, as the editor reads and writes it
// (docs/notes-graph-design.md, "Grammar"). `DocGraphSyntax` and `DailyNote`
// in Shared/Models/DocGraph.swift implement the same forms; a change here is
// a change there.
//
// - `text ^a1b2c3d4e`: a block's id, at the end of its own text. The editor
//   keeps it as an attribute of the block (see `blockIDAttribute` in
//   artifact-editor.js), so it is never drawn and never typed over.
// - `((a1b2c3d4e))`: an inline reference to a block.
// - `{{embed: ((a1b2c3d4e))}}`: a paragraph that is only an embed of a block
//   (Roam's own `{{[[embed]]: ((...))}}` is read too).
// - `[[Title]]`, `#tag`, `#[[Two words]]`: a page by its title. The Markdown
//   serializer may store the brackets escaped (`\[\[Title]]`) and a tag that
//   begins a line as `\#tag`; the patterns read both.

export const blockIDLength = 9
const blockIDAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'

/// A block id marker at the end of a block's own text, with the whitespace
/// before it, so taking it off leaves the words as they were.
const blockIDMarkerAtEnd = /(?:^|[ \t]+)\^([a-z0-9]{9})[ \t]*$/

/// A block reference anywhere in a run of text.
export const blockReferencePattern = /\(\(([a-z0-9]{9})\)\)/g

/// A paragraph that is nothing but an embed.
const blockEmbedPattern = /^\{\{\s*(?:\\?\[\\?\[)?embed(?:\\?\]\\?\])?\s*:\s*\(\(([a-z0-9]{9})\)\)\s*\}\}$/

/// A title link, `[[Title]]`, escaped or not.
export const titleLinkPattern = /\\?\[\\?\[((?:[^[\]\\\n]|\\[^\n])+?)\\?\]\\?\]/g

/// A tag: `#word` or `#[[Two words]]`, at the start of the text or after
/// whitespace or an opening parenthesis.
export const tagPattern = /(?:^|(?<=[\s(]))\\?#(?:\\?\[\\?\[((?:[^[\]\\\n]|\\[^\n])+?)\\?\]\\?\]|([\p{L}\p{N}_\-/]*[\p{L}\p{N}_][\p{L}\p{N}_\-/]*))/gu

/// Nine lowercase letters and digits, drawn evenly from the alphabet.
export function newBlockID() {
  let id = ''
  const bytes = new Uint8Array(16)
  while (id.length < blockIDLength) {
    crypto.getRandomValues(bytes)
    for (const byte of bytes) {
      // 252 is the largest multiple of 36 under 256: rejecting the rest keeps
      // every letter and digit equally likely.
      if (byte >= 252) continue
      id += blockIDAlphabet[byte % 36]
      if (id.length === blockIDLength) break
    }
  }
  return id
}

export function isBlockID(value) {
  return typeof value === 'string' && /^[a-z0-9]{9}$/.test(value)
}

export function blockReference(blockID) {
  return `((${blockID}))`
}

export function blockEmbed(blockID) {
  return `{{embed: ((${blockID}))}}`
}

/// The id a block's text ends with, and the text without it; null when the
/// text carries no marker.
export function takeBlockIDMarker(text) {
  const match = blockIDMarkerAtEnd.exec(String(text ?? ''))
  if (!match) return null
  return { text: text.slice(0, match.index), blockID: match[1] }
}

/// The block a paragraph's whole text embeds, or null.
export function embeddedBlockID(text) {
  const match = blockEmbedPattern.exec(String(text ?? '').trim())
  return match ? match[1] : null
}

/// A title as written inside a title link or a tag: a stored `\]` unescaped,
/// so `[[A \[draft\]]]` names "A [draft]".
export function unescapedTitle(raw) {
  let result = ''
  let escaping = false
  for (const character of String(raw ?? '')) {
    if (escaping) {
      result += character
      escaping = false
    } else if (character === '\\') {
      escaping = true
    } else {
      result += character
    }
  }
  if (escaping) result += '\\'
  return result.trim()
}

/// How two titles are compared, as `DocGraphSyntax.normalizedTitle` compares
/// them: case, accents, character width and runs of whitespace do not tell
/// titles apart.
export function normalizedTitle(title) {
  return String(title ?? '')
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .normalize('NFC')
    .split(/\s+/u)
    .filter(Boolean)
    .join(' ')
}

/// Every piece of the grammar in a run of text, in reading order, without
/// overlaps: `{ type: 'ref', blockID }`, `{ type: 'page', title }` for a
/// title link, `{ type: 'tag', title, bracketed }` for a tag, each with its
/// `start` and `end` offsets. A tag wins over the title link inside it.
export function graphTokens(text) {
  const value = String(text ?? '')
  const found = []
  if (value.includes('((')) {
    for (const match of value.matchAll(blockReferencePattern)) {
      found.push({ type: 'ref', start: match.index, end: match.index + match[0].length, blockID: match[1] })
    }
  }
  if (value.includes('#')) {
    for (const match of value.matchAll(tagPattern)) {
      const raw = match[1] ?? match[2] ?? ''
      const title = match[1] != null ? unescapedTitle(raw) : raw
      if (!title) continue
      found.push({
        type: 'tag',
        start: match.index,
        end: match.index + match[0].length,
        title,
        bracketed: match[1] != null,
      })
    }
  }
  if (value.includes('[')) {
    for (const match of value.matchAll(titleLinkPattern)) {
      const title = unescapedTitle(match[1])
      if (!title) continue
      found.push({ type: 'page', start: match.index, end: match.index + match[0].length, title })
    }
  }
  found.sort((left, right) => left.start - right.start || right.end - left.end)
  const tokens = []
  let reached = 0
  for (const token of found) {
    if (token.start < reached) continue
    tokens.push(token)
    reached = token.end
  }
  return tokens
}

// ─── Daily notes ────────────────────────────────────────────────────────────
// A daily note's id is its day, `daily-2026-10-06`, and its title the day
// written out, "October 6th, 2026" (`DailyNote` in DocGraph.swift). The day is
// the calendar day where the Mac is.

export const dailyNoteIDPrefix = 'daily-'
const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']

function pad(value, length) {
  return String(value).padStart(length, '0')
}

export function dayKeyFor(date) {
  return `${pad(date.getFullYear(), 4)}-${pad(date.getMonth() + 1, 2)}-${pad(date.getDate(), 2)}`
}

/// Local midnight of the day a key names, or null for a key that names no day.
export function dateForDayKey(dayKey) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(dayKey ?? ''))
  if (!match) return null
  const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  return dayKeyFor(date) === dayKey ? date : null
}

export function dailyNoteID(dayKey) {
  return `${dailyNoteIDPrefix}${dayKey}`
}

export function dayKeyOfDailyNoteID(id) {
  const value = String(id ?? '')
  if (!value.startsWith(dailyNoteIDPrefix)) return null
  const key = value.slice(dailyNoteIDPrefix.length)
  return dateForDayKey(key) ? key : null
}

export function ordinalSuffix(day) {
  const hundred = day % 100
  if (hundred >= 11 && hundred <= 13) return 'th'
  switch (day % 10) {
    case 1: return 'st'
    case 2: return 'nd'
    case 3: return 'rd'
    default: return 'th'
  }
}

/// "October 6th, 2026".
export function dayTitle(dayKey) {
  const date = dateForDayKey(dayKey)
  if (!date) return ''
  const day = date.getDate()
  return `${monthNames[date.getMonth()]} ${day}${ordinalSuffix(day)}, ${date.getFullYear()}`
}

/// A month written in full or cut short to at least three letters ("oct",
/// "sept"), or -1.
function monthIndex(name) {
  const value = String(name ?? '').toLowerCase().replace(/\.$/, '')
  if (value.length < 3) return -1
  return monthNames.findIndex((month) => month.toLowerCase().startsWith(value))
}

function keyFor(year, month, day) {
  const key = `${pad(year, 4)}-${pad(month + 1, 2)}-${pad(day, 2)}`
  return dateForDayKey(key) ? key : null
}

/// The day a title such as "October 6th, 2026" names, or null: how
/// `[[October 6th, 2026]]` finds its daily note before the note exists.
export function dayKeyFromTitle(title) {
  const match = /^\s*([A-Za-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\s*$/.exec(String(title ?? ''))
  if (!match) return null
  const month = monthIndex(match[1])
  if (month < 0) return null
  return keyFor(Number(match[3]), month, Number(match[2]))
}

function addDays(date, days) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days)
}

/// The days a picker query names, in the order to offer them: "today",
/// "tomorrow", "yesterday" (from their first three letters), a date written
/// out ("October 7th, 2026", "oct 7", "7 October") or an ISO date
/// ("2026-10-07"). A month and day without a year are this year's.
export function daysForQuery(query, now = new Date()) {
  const value = String(query ?? '').trim().toLowerCase().replace(/\s+/g, ' ')
  if (!value) return []
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const relative = [
    ['today', 0, 'Today'],
    ['tomorrow', 1, 'Tomorrow'],
    ['yesterday', -1, 'Yesterday'],
  ]
  const days = []
  for (const [word, offset, label] of relative) {
    if (value.length >= 3 && word.startsWith(value)) {
      days.push({ dayKey: dayKeyFor(addDays(today, offset)), label })
    }
  }
  if (days.length) return days

  let key = null
  let match = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(value)
  if (match) key = keyFor(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  if (!key) {
    match = /^([a-z]+)\.? (\d{1,2})(?:st|nd|rd|th)?(?:,? (\d{4}))?$/.exec(value)
    if (match && monthIndex(match[1]) >= 0) {
      key = keyFor(match[3] ? Number(match[3]) : today.getFullYear(), monthIndex(match[1]), Number(match[2]))
    }
  }
  if (!key) {
    match = /^(\d{1,2})(?:st|nd|rd|th)? ([a-z]+)\.?(?:,? (\d{4}))?$/.exec(value)
    if (match && monthIndex(match[2]) >= 0) {
      key = keyFor(match[3] ? Number(match[3]) : today.getFullYear(), monthIndex(match[2]), Number(match[1]))
    }
  }
  if (!key) return []
  const todayKey = dayKeyFor(today)
  const label = key === todayKey
    ? 'Today'
    : key === dayKeyFor(addDays(today, 1)) ? 'Tomorrow'
      : key === dayKeyFor(addDays(today, -1)) ? 'Yesterday'
        : 'Daily note'
  return [{ dayKey: key, label }]
}

/// The day `offset` days from today: 0 today, 1 tomorrow, -1 yesterday.
export function relativeDayKey(offset, now = new Date()) {
  return dayKeyFor(addDays(new Date(now.getFullYear(), now.getMonth(), now.getDate()), offset))
}
