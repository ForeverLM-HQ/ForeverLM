// Builds the LevelDB fixture behind ChromiumReadingListStoreTests: a Chromium
// `Sync Data/LevelDB` store with reading-list entries in both file formats — a
// compacted `.ldb` table (snappy-compressed blocks, one deleted entry) and a
// trailing `.log` with a title change, a read mark and a new entry.
//
// Regenerate only when the store format the test asserts against changes:
//
//   cd ForeverLMApp/scripts
//   npm install --no-save classic-level
//   node make_brave_sync_fixture.mjs /tmp/brave-sync-leveldb
//   cp /tmp/brave-sync-leveldb/000005.ldb ../UnitTests/Fixtures/brave-sync-000005.ldb
//   cp /tmp/brave-sync-leveldb/000004.log ../UnitTests/Fixtures/brave-sync-000004.log
//
// The `.log` fixture is force-added: `.gitignore` excludes `*.log`, so a plain
// `git add` skips it and the test then fails to find the file.
import { ClassicLevel } from 'classic-level'
import fs from 'node:fs'
const dir = process.argv[2]
fs.rmSync(dir, { recursive: true, force: true })
function varint(n) { n = BigInt(n); const out = []; while (n >= 0x80n) { out.push(Number(n & 0x7fn) | 0x80); n >>= 7n } out.push(Number(n)); return Buffer.from(out) }
function str(f, s) { const b = Buffer.from(s, 'utf8'); return Buffer.concat([varint((f << 3) | 2), varint(b.length), b]) }
function vint(f, v) { return Buffer.concat([varint(f << 3), varint(v)]) }
// ReadingListLocal: 1 entry_id, 2 title, 3 url, 4 creation_time_us, 5 update_time_us, 6 status (UNREAD=0, READ=1, UNSEEN=2), 11 first_read_time_us, 10 backoff
function entry({ url, title, created, status, firstRead }) {
  const parts = [str(1, url), str(2, title), str(3, url), vint(4, created), vint(5, created), vint(6, status), vint(7, 0), vint(9, 0), str(10, '[2,0,"-1","2"]')]
  if (firstRead) parts.push(vint(11, firstRead))
  parts.push(vint(12, created), vint(17, 0))
  return Buffer.concat(parts)
}
const db = new ClassicLevel(dir, { keyEncoding: 'buffer', valueEncoding: 'buffer', compression: true })
await db.open()
const k = u => Buffer.from('reading_list-dt-' + u)
// Sequence: three entries and unrelated keys, one entry removed, then compact so the survivors live in a .ldb
await db.put(k('https://example.org/alpha'), entry({ url: 'https://example.org/alpha', title: 'Alpha &amp; Omega', created: 1788926302227587, status: 2 }))
await db.put(k('https://example.org/beta'), entry({ url: 'https://example.org/beta', title: 'Beta (first title)', created: 1788926376142953, status: 0 }))
await db.put(k('https://example.org/removed'), entry({ url: 'https://example.org/removed', title: 'Removed later', created: 1788926388009484, status: 2 }))
await db.put(Buffer.from('reading_list-md-https://example.org/alpha'), Buffer.from('metadata, not an entry'))
await db.put(Buffer.from('bookmarks-dt-https://example.org/not-a-reading-list-entry'), Buffer.from('other data type'))
// padding so the table has more than one data block
for (let i = 0; i < 400; i++) await db.put(Buffer.from(`zz-padding-${String(i).padStart(4, '0')}`), Buffer.from('x'.repeat(200) + i))
await db.del(k('https://example.org/removed'))
await db.compactRange(Buffer.from([0]), Buffer.from([0xff]))
// After compaction: a title change and a read mark for beta, and a fourth entry, both left in the .log
await db.put(k('https://example.org/beta'), entry({ url: 'https://example.org/beta', title: 'Beta (renamed)', created: 1788926376142953, status: 1, firstRead: 1788930000000000 }))
await db.put(k('https://example.org/gamma'), entry({ url: 'https://example.org/gamma', title: 'Gamma', created: 1788926396871453, status: 2 }))
await db.close()
console.log(fs.readdirSync(dir).map(f => `${f} ${fs.statSync(dir + '/' + f).size}`).join('\n'))
