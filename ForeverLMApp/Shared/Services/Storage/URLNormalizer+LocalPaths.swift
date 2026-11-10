extension URLNormalizer {
    /// URL normalization v1 as the Mac computes it: a local file path normalizes against this
    /// Mac's content roots (`StorageService.relativeSourcePath`), so the same file on two Macs
    /// keeps one key. Every source id the Mac mints goes through here (`SourceIdentity`,
    /// `TeamContentIdentity`, the `url:` work key).
    static func normalize(_ urlString: String) -> String {
        normalize(urlString, localPath: StorageService.relativeSourcePath)
    }
}

extension WorkKey {
    /// A work key as the Mac computes it: a `url:` key naming a local file normalizes against this
    /// Mac's content roots, as `URLNormalizer.normalize(_:)` does. Clients without local files call
    /// `normalizeRemote(_:)`.
    static func normalize(_ key: String) -> String? {
        normalize(key, localPath: StorageService.relativeSourcePath)
    }
}
