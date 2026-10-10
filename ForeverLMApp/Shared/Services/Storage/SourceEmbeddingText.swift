import Foundation

/// The single source of truth for turning a source into embeddable chunks.
///
/// Both the live ingest path (`StudioViewModel`) and the background indexer
/// (`SourceEmbeddingIndexer`) build chunks through here, and the MCP search path
/// reuses the same splitter. Chunk ids are positional (`<sourceID>::chunk::NNNN`)
/// and the passage returned for a hit is looked up by that index, so every producer
/// MUST agree on chunk boundaries and ordering — a single implementation is the only
/// safe way to guarantee that.
enum SourceEmbeddingText {
    struct ChunkInput: Sendable {
        let id: String
        /// Text actually fed to the embedding model (header + chunk body).
        let embeddingText: String
        /// The raw passage, surfaced as evidence for a semantic hit.
        let passage: String
    }

    /// Split content into overlapping word windows sized for the contextual
    /// embedding's 256-token cap. Input past the cap is silently dropped by the
    /// framework, so windows must stay short enough that window + title prefix fits.
    static func textChunks(
        from content: String,
        targetWordCount: Int = EmbeddingSettings.chunkTargetWordCount,
        overlapWordCount: Int = EmbeddingSettings.chunkOverlapWordCount
    ) -> [String] {
        let words = content
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        guard !words.isEmpty else { return [] }
        guard words.count > targetWordCount else { return [words.joined(separator: " ")] }

        let overlap = min(max(0, overlapWordCount), max(0, targetWordCount - 1))
        var chunks: [String] = []
        var start = 0
        while start < words.count {
            let end = min(start + targetWordCount, words.count)
            chunks.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start = max(end - overlap, start + 1)
        }
        return chunks
    }

    /// Build the positional chunk inputs for a source. A source with no recoverable
    /// text still yields one header-only chunk so it stays findable by title.
    static func chunkInputs(
        sourceID: String,
        title: String,
        domain: String,
        content: String?
    ) -> [ChunkInput] {
        let header = headerPrefix(title: title, domain: domain)
        let chunks = textChunks(from: content ?? "")
        guard !chunks.isEmpty else {
            return [
                ChunkInput(
                    id: StorageService.sourceChunkEmbeddingId(sourceId: sourceID, index: 0),
                    embeddingText: header,
                    passage: header
                )
            ]
        }
        return chunks.enumerated().map { index, chunk in
            ChunkInput(
                id: StorageService.sourceChunkEmbeddingId(sourceId: sourceID, index: index),
                embeddingText: "\(header)\nChunk \(index + 1) of \(chunks.count):\n\(chunk)",
                passage: chunk
            )
        }
    }

    /// The metadata header prepended to every chunk. The title is capped so a very
    /// long title cannot, together with the chunk body, overflow the token limit and
    /// truncate the body it is supposed to contextualize.
    private static func headerPrefix(title: String, domain: String) -> String {
        let titleWords = title.split(separator: " ")
        let cappedTitle = titleWords.count > EmbeddingSettings.chunkTitlePrefixWordCount
            ? titleWords.prefix(EmbeddingSettings.chunkTitlePrefixWordCount).joined(separator: " ") + "…"
            : title
        return "Title: \(cappedTitle)\nSource: \(domain)"
    }
}
