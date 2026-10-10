import Foundation

// MARK: - Written faces: the background pass (WP-B1, docs/sensemaking-design.md)
//
// In the rhythm of the Canvas Summaries: two seconds after the cards or the
// layout settle, the drawn source cards' stored faces are read and shown, and
// those missing or written from other text are written, twelve to a call,
// while the daily background AI cap allows. Nothing is written with Written
// Faces off.

extension StudioViewModel {
    /// Shows the drawn source cards' written faces, and writes the ones they
    /// lack. A burst of moves asks once; a request while a pass runs makes it
    /// run once more when it ends.
    func refreshKnowledgeMapFaces() async {
        let state = knowledgeMap.facesState
        state.request &+= 1
        let request = state.request
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard state.request == request else { return }
        guard !state.isRunning else {
            state.runAgain = true
            return
        }
        state.isRunning = true
        defer { state.isRunning = false }
        repeat {
            state.runAgain = false
            await knowledgeMapFacesPass()
        } while state.runAgain
    }

    private func knowledgeMapFacesPass() async {
        let map = knowledgeMap
        let state = map.facesState
        let drawn = map.drawnSourceIDs
        guard !drawn.isEmpty else { return }

        // What is stored already shows at once, AI or not.
        let unlooked = drawn.filter { !state.looked.contains($0) }
        if !unlooked.isEmpty {
            do {
                let stored = try await storage.sourceFacesRows(sourceIDs: unlooked)
                state.looked.formUnion(unlooked)
                map.storeFaces(Array(stored.values))
            } catch {
                logger.error("Canvas faces could not be read: \(error.localizedDescription)")
                return
            }
        }
        guard map.showsWrittenFaces else { return }
        if let failedAt = state.failedAt, Date().timeIntervalSince(failedAt) < KnowledgeMapFacesState.retryAfterFailure { return }

        // Each source's fingerprint, read again only when its title, length
        // or state changed. A paper still being prepared has no text to read.
        let drawnSet = Set(drawn)
        var articles: [String: StudioArticle] = [:]
        for article in self.articles where drawnSet.contains(article.id) { articles[article.id] = article }
        let readable = drawn.filter { id in
            guard let article = articles[id] else { return false }
            return article.sourceType != .paper || article.state == .ready
        }
        let stale = readable.filter { id in
            guard let article = articles[id] else { return false }
            return state.fingerprints[id]?.signature != KnowledgeMapFaces.signature(of: article)
        }
        var texts: [String: KnowledgeMapFaces.SourceText] = [:]
        if !stale.isEmpty {
            do {
                texts = try await storage.sourceFaceTexts(sourceIDs: stale)
            } catch {
                logger.error("Canvas faces could not read their sources: \(error.localizedDescription)")
                return
            }
            let titles = stale.compactMap { id in articles[id].map { (id, $0.title) } }
            let fingerprints = await Self.facesFingerprints(titles: titles, texts: texts)
            for (id, _) in titles {
                guard let article = articles[id] else { continue }
                // A source with nothing to write from yet keeps an empty
                // fingerprint, and is read again once it changes.
                state.fingerprints[id] = (KnowledgeMapFaces.signature(of: article), fingerprints[id] ?? "")
            }
        }
        let current = Dictionary(readable.compactMap { id in
            state.fingerprints[id].flatMap { $0.fingerprint.isEmpty ? nil : (id, $0.fingerprint) }
        }, uniquingKeysWith: { first, _ in first })
        let needing = KnowledgeMapFaces.needingFaces(readable, fingerprints: current, rows: state.rows, unanswered: state.unanswered)
        guard !needing.isEmpty else { return }

        guard let config = KeychainService.resolveConfig(for: .mapSummaries) else {
            logger.info("Canvas faces wait: \(KeychainService.backgroundAIUnavailableMessage(for: .mapSummaries) ?? "no Canvas Summaries model is set up")")
            return
        }
        // A source read for an earlier pass is read again now for its text.
        let missingText = needing.filter { texts[$0] == nil }
        if !missingText.isEmpty {
            do {
                texts.merge(try await storage.sourceFaceTexts(sourceIDs: missingText)) { _, new in new }
            } catch {
                logger.error("Canvas faces could not read their sources: \(error.localizedDescription)")
                return
            }
        }
        let inputs: [KnowledgeMapFaces.Input] = needing.compactMap { id in
            guard let text = texts[id], let fingerprint = current[id],
                  let node = map.nodesByRef[KnowledgeMap.ItemRef(kind: .source, id: id).description] else { return nil }
            return KnowledgeMapFaces.Input(sourceID: id, title: node.title, byline: node.sub, type: node.type, text: text, fingerprint: fingerprint)
        }
        for batch in KnowledgeMapFaces.batches(inputs) {
            guard await backgroundAIBudget.check().allowsBackgroundSpend else {
                logger.info("Canvas faces wait for tomorrow: the daily background AI limit is reached")
                return
            }
            guard map.showsWrittenFaces else { return }
            do {
                let written = try await aiService.knowledgeMapFaces(batch, config: config)
                let now = Date()
                let rows = batch.compactMap { input -> SourceFacesRow? in
                    guard let face = written[input.sourceID] else { return nil }
                    return SourceFacesRow(
                        sourceID: input.sourceID, fingerprint: input.fingerprint,
                        far: face.far, mid: face.mid, near: face.near,
                        model: config.model, createdAt: now
                    )
                }
                for input in batch where written[input.sourceID] == nil { state.unanswered.insert(input.fingerprint) }
                try await storage.saveSourceFacesRows(rows)
                map.storeFaces(rows)
            } catch {
                state.failedAt = Date()
                logger.error("Canvas faces failed: \(error.localizedDescription)")
                return
            }
        }
    }

    /// Each source's fingerprint, worked out off the main actor; a source with
    /// nothing to write from has none.
    nonisolated private static func facesFingerprints(
        titles: [(String, String)],
        texts: [String: KnowledgeMapFaces.SourceText]
    ) async -> [String: String] {
        var result: [String: String] = [:]
        for (id, title) in titles {
            guard let text = texts[id] else { continue }
            result[id] = KnowledgeMapFaces.fingerprint(title: title, text: text)
        }
        return result
    }
}
