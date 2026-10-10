import Foundation
import CryptoKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Persistent disk cache for source thumbnails (books, papers, articles, podcasts).
/// Thumbnails are tiny JPEGs (~2-10 KB each) stored in ~/Library/Caches/Thumbnails/.
/// Not synced to iCloud — purely a local performance cache.
final class ThumbnailDiskCache: @unchecked Sendable {
    static let shared = ThumbnailDiskCache()

    private let cacheDirectory: URL

    /// All encoding and file writes happen on this queue so callers (often the
    /// main actor) never block on JPEG encoding or disk I/O.
    private let ioQueue = DispatchQueue(label: "com.foreverlm.thumbnail-disk-cache", qos: .utility)

    /// Individually these files are nothing, but nothing ever removed one, and
    /// a library that keeps gaining sources keeps gaining thumbnails. Half a
    /// year, capped at 250 MB, outlasts any thumbnail a reader still scrolls
    /// past; anything evicted is re-fetched the next time its row is drawn.
    private static let diskBudget: Int64 = 250 * 1024 * 1024
    private static let lifetime: TimeInterval = 180 * 24 * 60 * 60

    /// Read and written only on `ioQueue`, which is what keeps the sweep to one
    /// per launch without a lock.
    private var hasSwept = false

    private init() {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = base.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// Test-only initializer that uses a custom cache directory.
    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    func cacheFileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hash + ".jpg")
    }

    /// Read a cached thumbnail from disk.
    func cachedImage(for key: String) -> PlatformImage? {
        let fileURL = cacheFileURL(for: key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return PlatformImage(contentsOfFile: fileURL.path)
    }

    /// Write a thumbnail image to disk as JPEG. Fire-and-forget: encoding and
    /// the write run on a background queue, never on the caller's thread.
    func store(_ image: PlatformImage, for key: String) {
        // Take an immutable snapshot here, on the caller's own thread, instead
        // of handing the image itself to `ioQueue`. Callers store the same
        // instance in `ImageCache` and hand it straight to SwiftUI, so reading
        // it from a utility-QoS queue makes the main thread block on NSImage's
        // internal representation lock behind background work — the priority
        // inversion the Thread Performance Checker flags. A CGImage is
        // immutable and shares no lock with the image the UI is drawing.
        guard let snapshot = Self.snapshot(of: image) else { return }
        let fileURL = cacheFileURL(for: key)
        ioQueue.async { [cacheDirectory] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: cacheDirectory.path) {
                try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            }
            if !self.hasSwept {
                self.hasSwept = true
                CacheDirectorySweep.sweep(
                    directory: cacheDirectory,
                    maximumBytes: Self.diskBudget,
                    maximumAge: Self.lifetime
                )
            }

            guard let data = Self.jpegData(from: snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func snapshot(of image: PlatformImage) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    private static func jpegData(from image: CGImage) -> Data? {
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #else
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
        #endif
    }
}
