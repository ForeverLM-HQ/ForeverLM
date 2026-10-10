import Foundation

/// Trims a disk cache back under a ceiling, least recently read first.
///
/// A cache only earns the name if something eventually takes files out of it.
/// `GoogleDriveRecordings` never did: every meeting recording this Mac opened
/// stayed on disk for good, and because the cache key folds in the Drive file's
/// modification date, re-uploading a recording orphaned the old copy instead of
/// replacing it. It reached 8.6 GB on a disk that was being cleared by hand
/// every week.
///
/// The policy is deliberately blunt, because a sweep that has to be reasoned
/// about is a sweep that gets skipped: drop whatever is older than
/// `maximumAge`, then, while the directory still exceeds `maximumBytes`, drop
/// whatever was read longest ago. Everything these callers keep can be fetched
/// again, so evicting a file that is still wanted costs one download rather
/// than lost work — which is what lets the sweep ignore whether a file is in
/// use. Unlinking a file another thread is reading is safe on Darwin; the open
/// descriptor keeps the bytes alive until it closes.
///
/// Only regular files sitting directly in `directory` are considered. Nothing
/// recurses, so a cache that grows subdirectories needs its own sweep rather
/// than a flag on this one.
enum CacheDirectorySweep {

    private struct Entry {
        let url: URL
        let size: Int64
        let lastUsed: Date
    }

    /// Returns the number of bytes reclaimed, which is 0 for a directory that
    /// does not exist yet — the first run on a fresh install is not a failure.
    @discardableResult
    static func sweep(
        directory: URL,
        maximumBytes: Int64,
        maximumAge: TimeInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
        ]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else {
            return 0
        }

        var files: [Entry] = []
        var total: Int64 = 0
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            // Read time is what "least recently used" ought to mean, but a
            // volume that does not update it leaves every file looking equally
            // cold, so the write time stands in whenever it is the later of the
            // two.
            let accessed = values.contentAccessDate ?? .distantPast
            let modified = values.contentModificationDate ?? .distantPast
            files.append(Entry(url: url, size: size, lastUsed: max(accessed, modified)))
            total += size
        }

        var reclaimed: Int64 = 0
        var survivors: [Entry] = []
        let cutoff = now.addingTimeInterval(-maximumAge)
        for file in files {
            guard file.lastUsed < cutoff else {
                survivors.append(file)
                continue
            }
            do {
                try fileManager.removeItem(at: file.url)
                reclaimed += file.size
                total -= file.size
            } catch {
                // A file that will not delete is one the next sweep can try
                // again; it must not stop this one from reaching the ceiling.
                survivors.append(file)
            }
        }

        guard total > maximumBytes else { return reclaimed }
        for file in survivors.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard total > maximumBytes else { break }
            do {
                try fileManager.removeItem(at: file.url)
                reclaimed += file.size
                total -= file.size
            } catch {
                continue
            }
        }
        return reclaimed
    }
}
