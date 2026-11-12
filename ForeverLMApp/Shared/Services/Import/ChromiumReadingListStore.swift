import Foundation

/// Reads a Chromium browser's reading list out of its sync model-type store.
///
/// Chrome (since 2024) and Brave keep reading-list entries in
/// `<profile>/Sync Data/LevelDB`, a LevelDB whose keys are
/// `reading_list-dt-<url>` and whose values are `ReadingListLocal` protobufs
/// (components/reading_list/core/proto/reading_list.proto). Brave writes there
/// whether or not Brave Sync is turned on; the `Bookmarks` JSON file does not
/// carry a `reading_list` root.
///
/// Chrome keeps a second store in the same LevelDB for the Google account the
/// profile is signed in to, its keys prefixed `A-`
/// (components/sync/model/blocking_data_type_store_impl.cc). A profile signed
/// in without Sync saves only there, and Chrome's sync-to-signin migration
/// moves a syncing profile's whole list there, deleting every unprefixed key.
/// Chrome shows the two stores as one list, merging an entry both hold, and so
/// does this reader.
///
/// The store has to be read as a LevelDB, not scanned for URLs:
///
/// - Entries the browser removed are still present in the log as earlier
///   puts; only the deletion record that follows says they are gone.
/// - Once the write-ahead log reaches its buffer size the browser compacts it
///   into an `.ldb` table whose blocks are snappy-compressed, and a byte scan
///   finds nothing in them at all.
/// - The title, when the entry was saved, and whether it has been read are in
///   the protobuf, which is what lets a Brave entry enter the library the way
///   a Safari Reading List entry does.
///
/// Both file formats are decoded here (log write batches; table footer, index
/// and data blocks; snappy) and the newest sequence number per key wins, as
/// LevelDB itself resolves them. A file that does not parse falls back to the
/// old URL scan so a corrupt file still yields its URLs rather than nothing.
enum ChromiumReadingListStore {

    /// `ReadingListLocal.status`, in the proto's own numbering.
    enum Status: Int, Equatable {
        case unread = 0
        case read = 1
        case unseen = 2
    }

    struct Entry: Equatable {
        let url: String
        /// The title as the browser stored it; empty titles fall back to the URL.
        let title: String
        let creationTime: Date?
        let firstReadTime: Date?
        let status: Status

        var isRead: Bool { status == .read }
    }

    static let keyPrefix = "reading_list-dt-"
    /// The signed-in account's store: `A-` before the data type's root tag.
    static let accountKeyPrefix = "A-" + keyPrefix

    /// Every live reading-list entry in the store, oldest saved first.
    static func entries(inSyncDirectory syncDir: String) -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: syncDir) else { return [] }

        var latest: [String: (sequence: UInt64, value: [UInt8]?)] = [:]
        var scannedURLs = Set<String>()
        let localPrefix = Array(keyPrefix.utf8)
        let accountPrefix = Array(accountKeyPrefix.utf8)

        for file in files.sorted() {
            let path = (syncDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path), !data.isEmpty else { continue }
            let bytes = [UInt8](data)

            let records: [LevelDBRecord]?
            if file.hasSuffix(".log") {
                records = LevelDBLog.records(in: bytes)
            } else if file.hasSuffix(".ldb") || file.hasSuffix(".sst") {
                records = LevelDBTable.records(in: bytes)
            } else {
                continue
            }

            guard let records else {
                scannedURLs.formUnion(scanForEntryURLs(in: bytes))
                continue
            }
            for record in records {
                guard record.key.starts(with: localPrefix) || record.key.starts(with: accountPrefix),
                      let key = String(bytes: record.key, encoding: .utf8) else { continue }
                if let existing = latest[key], existing.sequence >= record.sequence { continue }
                latest[key] = (record.sequence, record.value)
            }
        }

        var local: [String: StoredEntry] = [:]
        var account: [String: StoredEntry] = [:]
        for (key, record) in latest {
            guard let value = record.value else { continue } // deleted since
            if key.hasPrefix(accountKeyPrefix) {
                let keyURL = String(key.dropFirst(accountKeyPrefix.count))
                account[keyURL] = decodeStoredEntry(value, keyURL: keyURL)
            } else {
                let keyURL = String(key.dropFirst(keyPrefix.count))
                local[keyURL] = decodeStoredEntry(value, keyURL: keyURL)
            }
        }
        // Chrome's DualReadingListModel: an entry in both stores is the local
        // one with the account's merged in.
        var merged = local
        for (keyURL, accountEntry) in account {
            merged[keyURL] = local[keyURL].map { $0.merging(accountEntry) } ?? accountEntry
        }

        var result = merged.values.map(\.entry)
        for url in scannedURLs
        where latest[keyPrefix + url] == nil && latest[accountKeyPrefix + url] == nil {
            result.append(Entry(url: url, title: url, creationTime: nil, firstReadTime: nil, status: .unread))
        }
        return result.sorted { lhs, rhs in
            let l = lhs.creationTime ?? .distantPast
            let r = rhs.creationTime ?? .distantPast
            return l == r ? lhs.url < rhs.url : l < r
        }
    }

    // MARK: - ReadingListLocal

    /// An entry with the clocks Chrome merges by, all in microseconds since
    /// the Unix epoch and 0 when unset, as `ReadingListEntry` holds them.
    struct StoredEntry: Equatable {
        var url: String
        var title: String
        var creationMicros: UInt64
        var updateMicros: UInt64
        var titleUpdateMicros: UInt64
        var firstReadMicros: UInt64
        var status: Status

        var entry: Entry {
            Entry(
                url: url,
                title: title.isEmpty ? url : title,
                creationTime: ChromiumReadingListStore.date(fromMicroseconds: creationMicros),
                firstReadTime: ChromiumReadingListStore.date(fromMicroseconds: firstReadMicros),
                status: status
            )
        }

        /// `ReadingListEntry::MergeWithEntry`
        /// (components/reading_list/core/reading_list_entry.cc): the newer
        /// title, the newer save with its first read, and the newer status.
        func merging(_ other: StoredEntry) -> StoredEntry {
            var result = self
            if titleUpdateMicros < other.titleUpdateMicros {
                result.title = other.title
                result.titleUpdateMicros = other.titleUpdateMicros
            } else if titleUpdateMicros == other.titleUpdateMicros,
                      Array(title.utf8).lexicographicallyPrecedes(Array(other.title.utf8)) {
                result.title = other.title
            }
            if creationMicros < other.creationMicros {
                result.creationMicros = other.creationMicros
                result.firstReadMicros = other.firstReadMicros
            } else if creationMicros == other.creationMicros,
                      firstReadMicros == 0 || (other.firstReadMicros != 0 && other.firstReadMicros < firstReadMicros) {
                result.firstReadMicros = other.firstReadMicros
            }
            if updateMicros < other.updateMicros {
                result.updateMicros = other.updateMicros
                result.status = other.status
            } else if updateMicros == other.updateMicros,
                      status == .unseen || other.status == .read {
                result.status = other.status
            }
            return result
        }
    }

    static func decodeStoredEntry(_ value: [UInt8], keyURL: String) -> StoredEntry {
        var entryID: String?
        var title: String?
        var url: String?
        var creationMicros: UInt64 = 0
        var updateMicros: UInt64 = 0
        var titleUpdateMicros: UInt64 = 0
        var firstReadMicros: UInt64 = 0
        var status: Status = .unread

        var p = 0
        fields: while p < value.count {
            guard let tag = readVarint(value, &p) else { break }
            let field = tag >> 3
            switch tag & 7 {
            case 0:
                guard let number = readVarint(value, &p) else { break fields }
                switch field {
                case 4: creationMicros = number
                case 5: updateMicros = number
                case 6: status = Status(rawValue: Int(truncatingIfNeeded: number)) ?? .unread
                case 11: firstReadMicros = number
                case 12: titleUpdateMicros = number
                default: break
                }
            case 1:
                p += 8
            case 2:
                guard let length = readVarint(value, &p), p + Int(length) <= value.count else { break fields }
                let text = String(bytes: value[p..<p + Int(length)], encoding: .utf8)
                p += Int(length)
                switch field {
                case 1: entryID = text
                case 2: title = text
                case 3: url = text
                default: break
                }
            case 5:
                p += 4
            default:
                break fields
            }
        }

        let resolvedURL = [url, entryID].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? keyURL
        return StoredEntry(
            url: resolvedURL,
            title: title ?? "",
            creationMicros: creationMicros,
            updateMicros: updateMicros,
            titleUpdateMicros: titleUpdateMicros,
            firstReadMicros: firstReadMicros,
            status: status
        )
    }

    /// `creation_time_us` and friends are microseconds since the Unix epoch.
    private static func date(fromMicroseconds micros: UInt64) -> Date? {
        guard micros > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    }

    // MARK: - Fallback scan

    /// The pre-structured reader: every `reading_list-dt-` key whose bytes are
    /// stored in the clear, the account store's `A-` keys among them. Kept for
    /// files that fail to parse as LevelDB.
    static func scanForEntryURLs(in bytes: [UInt8]) -> Set<String> {
        let marker = Array(keyPrefix.utf8)
        var urls = Set<String>()
        guard bytes.count > marker.count else { return urls }
        var i = 0
        while i + marker.count <= bytes.count {
            guard bytes[i] == marker[0], Array(bytes[i..<i + marker.count]) == marker else {
                i += 1
                continue
            }
            var end = i + marker.count
            while end < bytes.count, bytes[end] >= 33, bytes[end] < 127 { end += 1 }
            if end > i + marker.count,
               let url = String(bytes: bytes[(i + marker.count)..<end], encoding: .ascii),
               url.hasPrefix("http") {
                urls.insert(url)
            }
            i = end
        }
        return urls
    }

    // MARK: - LevelDB

    struct LevelDBRecord: Equatable {
        let key: [UInt8]
        let sequence: UInt64
        /// nil for a deletion.
        let value: [UInt8]?
    }

    /// The write-ahead log: 32 KB blocks of framed fragments, each full record a
    /// write batch of puts and deletes stamped with a base sequence number.
    enum LevelDBLog {
        static let blockSize = 32 * 1024

        static func records(in bytes: [UInt8]) -> [LevelDBRecord]? {
            var records: [LevelDBRecord] = []
            var pending: [UInt8] = []
            var pos = 0
            var parsedAnyBatch = false

            while pos + 7 <= bytes.count {
                let remainingInBlock = blockSize - (pos % blockSize)
                if remainingInBlock < 7 {
                    pos += remainingInBlock
                    continue
                }
                let length = Int(bytes[pos + 4]) | (Int(bytes[pos + 5]) << 8)
                let type = bytes[pos + 6]
                pos += 7
                // A record the browser is still writing ends the readable log. A
                // file that never yielded a batch is not a log at all: hand it to
                // the URL scan rather than reporting an empty store.
                guard pos + length <= bytes.count else { return parsedAnyBatch ? records : nil }
                let fragment = bytes[pos..<pos + length]
                pos += length

                let batch: [UInt8]
                switch type {
                case 1:
                    batch = Array(fragment)
                case 2:
                    pending = Array(fragment)
                    continue
                case 3:
                    pending += fragment
                    continue
                case 4:
                    pending += fragment
                    batch = pending
                    pending = []
                case 0 where length == 0:
                    // Preallocated, never-written space: the end of the log.
                    return parsedAnyBatch ? records : nil
                default:
                    return parsedAnyBatch ? records : nil
                }

                guard let batchRecords = parseWriteBatch(batch) else {
                    return parsedAnyBatch ? records : nil
                }
                records += batchRecords
                parsedAnyBatch = true
            }
            return parsedAnyBatch ? records : nil
        }

        static func parseWriteBatch(_ batch: [UInt8]) -> [LevelDBRecord]? {
            guard batch.count >= 12 else { return nil }
            let sequence = readLittleEndian(batch, at: 0, count: 8)
            let count = Int(readLittleEndian(batch, at: 8, count: 4))
            var p = 12
            var records: [LevelDBRecord] = []
            for index in 0..<count {
                guard p < batch.count else { return nil }
                let type = batch[p]
                p += 1
                guard let keyLength = readVarint(batch, &p), p + Int(keyLength) <= batch.count else { return nil }
                let key = Array(batch[p..<p + Int(keyLength)])
                p += Int(keyLength)
                switch type {
                case 1:
                    guard let valueLength = readVarint(batch, &p), p + Int(valueLength) <= batch.count else { return nil }
                    let value = Array(batch[p..<p + Int(valueLength)])
                    p += Int(valueLength)
                    records.append(LevelDBRecord(key: key, sequence: sequence + UInt64(index), value: value))
                case 0:
                    records.append(LevelDBRecord(key: key, sequence: sequence + UInt64(index), value: nil))
                default:
                    return nil
                }
            }
            return records
        }
    }

    /// A sorted table (`.ldb`): a footer that locates the index block, whose
    /// entries locate the data blocks; each block is a run of prefix-compressed
    /// key/value pairs, optionally snappy-compressed as a whole.
    enum LevelDBTable {
        static let magic: UInt64 = 0xdb47_7524_8b80_fb57
        static let footerLength = 48

        static func records(in bytes: [UInt8]) -> [LevelDBRecord]? {
            guard bytes.count >= footerLength else { return nil }
            let footerStart = bytes.count - footerLength
            guard readLittleEndian(bytes, at: footerStart + 40, count: 8) == magic else { return nil }

            var p = footerStart
            guard let _ = readBlockHandle(bytes, &p),
                  let indexHandle = readBlockHandle(bytes, &p),
                  let indexBlock = readBlock(bytes, handle: indexHandle),
                  let indexEntries = parseBlock(indexBlock) else { return nil }

            var records: [LevelDBRecord] = []
            for indexEntry in indexEntries {
                var q = 0
                guard let handle = readBlockHandle(indexEntry.value, &q),
                      let block = readBlock(bytes, handle: handle),
                      let pairs = parseBlock(block) else { return nil }
                for pair in pairs {
                    // Internal key: user key + 8 bytes of (sequence << 8 | type).
                    guard pair.key.count >= 8 else { return nil }
                    let trailer = readLittleEndian(pair.key, at: pair.key.count - 8, count: 8)
                    let userKey = Array(pair.key[0..<(pair.key.count - 8)])
                    let type = trailer & 0xff
                    records.append(LevelDBRecord(
                        key: userKey,
                        sequence: trailer >> 8,
                        value: type == 1 ? pair.value : nil
                    ))
                }
            }
            return records
        }

        struct BlockHandle {
            let offset: Int
            let size: Int
        }

        static func readBlockHandle(_ bytes: [UInt8], _ p: inout Int) -> BlockHandle? {
            guard let offset = readVarint(bytes, &p), let size = readVarint(bytes, &p),
                  offset <= UInt64(Int.max), size <= UInt64(Int.max) else { return nil }
            return BlockHandle(offset: Int(offset), size: Int(size))
        }

        /// The block's bytes, decompressed. Every block is followed by a one-byte
        /// compression type and a four-byte CRC.
        static func readBlock(_ bytes: [UInt8], handle: BlockHandle) -> [UInt8]? {
            guard handle.offset >= 0, handle.size >= 0,
                  handle.offset + handle.size + 5 <= bytes.count else { return nil }
            let raw = bytes[handle.offset..<handle.offset + handle.size]
            switch bytes[handle.offset + handle.size] {
            case 0: return Array(raw)
            case 1: return Snappy.decompress(raw)
            default: return nil // zstd and anything newer: not a format this store has used
            }
        }

        static func parseBlock(_ block: [UInt8]) -> [(key: [UInt8], value: [UInt8])]? {
            guard block.count >= 4 else { return nil }
            let restartCount = Int(readLittleEndian(block, at: block.count - 4, count: 4))
            let trailerLength = 4 * (restartCount + 1)
            guard trailerLength <= block.count else { return nil }
            let limit = block.count - trailerLength

            var entries: [(key: [UInt8], value: [UInt8])] = []
            var lastKey: [UInt8] = []
            var p = 0
            while p < limit {
                guard let shared = readVarint(block, &p),
                      let nonShared = readVarint(block, &p),
                      let valueLength = readVarint(block, &p),
                      Int(shared) <= lastKey.count,
                      p + Int(nonShared) + Int(valueLength) <= limit else { return nil }
                let key = Array(lastKey[0..<Int(shared)]) + Array(block[p..<p + Int(nonShared)])
                p += Int(nonShared)
                let value = Array(block[p..<p + Int(valueLength)])
                p += Int(valueLength)
                entries.append((key, value))
                lastKey = key
            }
            return entries
        }
    }

    /// Snappy's block format: a varint uncompressed length, then literals and
    /// back-references with one-, two- or four-byte offsets.
    enum Snappy {
        static func decompress(_ input: ArraySlice<UInt8>) -> [UInt8]? {
            let bytes = Array(input)
            var p = 0
            guard let expected = readVarint(bytes, &p), expected <= UInt64(Int.max) else { return nil }
            var out: [UInt8] = []
            out.reserveCapacity(Int(expected))

            while p < bytes.count {
                let tag = bytes[p]
                p += 1
                var length: Int
                var offset = 0
                switch tag & 3 {
                case 0:
                    length = Int(tag >> 2)
                    if length >= 60 {
                        let extra = length - 59
                        guard p + extra <= bytes.count else { return nil }
                        length = Int(readLittleEndian(bytes, at: p, count: extra))
                        p += extra
                    }
                    length += 1
                    guard p + length <= bytes.count else { return nil }
                    out += bytes[p..<p + length]
                    p += length
                    continue
                case 1:
                    length = 4 + Int((tag >> 2) & 0x7)
                    guard p + 1 <= bytes.count else { return nil }
                    offset = (Int(tag & 0xe0) << 3) | Int(bytes[p])
                    p += 1
                case 2:
                    length = Int(tag >> 2) + 1
                    guard p + 2 <= bytes.count else { return nil }
                    offset = Int(readLittleEndian(bytes, at: p, count: 2))
                    p += 2
                default:
                    length = Int(tag >> 2) + 1
                    guard p + 4 <= bytes.count else { return nil }
                    offset = Int(readLittleEndian(bytes, at: p, count: 4))
                    p += 4
                }
                guard offset > 0, offset <= out.count else { return nil }
                let start = out.count - offset
                // Copies may overlap their own output, so append byte by byte.
                for i in 0..<length {
                    out.append(out[start + i])
                }
            }
            guard out.count == Int(expected) else { return nil }
            return out
        }
    }

    // MARK: - Byte helpers

    static func readVarint(_ bytes: [UInt8], _ p: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while p < bytes.count, shift < 64 {
            let byte = bytes[p]
            p += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func readLittleEndian(_ bytes: [UInt8], at start: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count where start + i < bytes.count {
            value |= UInt64(bytes[start + i]) << (8 * UInt64(i))
        }
        return value
    }
}
