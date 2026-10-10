import SwiftUI

// MARK: - Shared In-Memory Image Cache

/// Process-lifetime image cache backed by NSCache.
/// Survives SwiftUI view rebuilds so thumbnails don't re-download on tab switch.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, PlatformImageWrapper>()

    private init() {
        cache.countLimit = 300
    }

    func image(for key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func set(_ image: PlatformImage, for key: String) {
        cache.setObject(PlatformImageWrapper(image), forKey: key as NSString)
    }

    /// Store to both in-memory and disk cache.
    func set(_ image: PlatformImage, for key: String, toDisk: Bool) {
        cache.setObject(PlatformImageWrapper(image), forKey: key as NSString)
        if toDisk {
            ThumbnailDiskCache.shared.store(image, for: key)
        }
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// NSCache requires reference-type values.
private final class PlatformImageWrapper {
    let image: PlatformImage
    init(_ image: PlatformImage) { self.image = image }
}

// MARK: - CachedAsyncImage

/// Drop-in replacement for AsyncImage that checks ImageCache first.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                await load()
            }
    }

    @MainActor
    private func load() async {
        guard let url else {
            phase = .empty
            return
        }

        let key = url.absoluteString

        // In-memory cache: safe to check on the main actor
        if let cached = ImageCache.shared.image(for: key) {
            #if os(macOS)
            phase = .success(Image(nsImage: cached))
            #else
            phase = .success(Image(uiImage: cached))
            #endif
            return
        }

        // Disk cache: file I/O must stay off the main actor
        let diskImage = await Task.detached(priority: .userInitiated) {
            ThumbnailDiskCache.shared.cachedImage(for: key)
        }.value
        if let diskImage {
            ImageCache.shared.set(diskImage, for: key)
            #if os(macOS)
            phase = .success(Image(nsImage: diskImage))
            #else
            phase = .success(Image(uiImage: diskImage))
            #endif
            return
        }

        // Download
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let platformImage = PlatformImage(data: data) else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }
            ImageCache.shared.set(platformImage, for: key, toDisk: true)
            #if os(macOS)
            phase = .success(Image(nsImage: platformImage))
            #else
            phase = .success(Image(uiImage: platformImage))
            #endif
        } catch {
            phase = .failure(error)
        }
    }
}
