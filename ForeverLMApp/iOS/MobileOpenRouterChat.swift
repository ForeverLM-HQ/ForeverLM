import CryptoKit
import Foundation

/// The mobile targets do not compile the shared macOS AI service, so this is
/// their managed text request builder: OpenRouter's chat completions, the one
/// text transport. Keeping it shared by source chat, review, and the voice
/// router keeps every request shape consistent on mobile.
///
/// Split out of MobileSourceChatService so it can also be compiled into the
/// macOS app target, where it is otherwise unused: the unit tests cover the
/// cache-marker and session-id shape through `@testable import ForeverLM`, and
/// the rest of that service pulls in CloudKit usage recording the Mac already
/// has its own path for. `ManagedAI` is the only dependency, and every target
/// that compiles this file already has it.
enum MobileOpenRouterChat {
    static func request(
        route: ResolvedAITextRoute,
        system: String,
        messages: [(role: String, content: String)],
        maxTokens: Int,
        jsonMode: Bool = false,
        stream: Bool = false
    ) throws -> URLRequest {
        guard route.provider == "OpenRouter" else {
            throw MobileSourceChatError.badResponse("The selected AI provider \(route.provider) is unsupported.")
        }
        let model = route.model
        let lowered = model.lowercased()
        // The same per-model rule as the Mac's `AIService`, so a family that
        // needs explicit breakpoints (Anthropic, Gemini, GPT-5.6 and later,
        // Qwen) gets them on the phone too.
        let explicitTTL: String?
        let explicit: Bool
        switch OpenRouterCachePolicy.policy(for: model) {
        case .explicitBreakpoints(let ttl):
            explicit = true
            explicitTTL = ttl
        case .implicit, .unsupported, .unverified:
            explicit = false
            explicitTTL = nil
        }

        var payloadMessages: [[String: Any]] = [["role": "system", "content": system]]
        payloadMessages.append(contentsOf: messages.map {
            ["role": $0.role, "content": $0.content] as [String: Any]
        })
        payloadMessages = ChatRequestTurnOrder.endingOnAnswerableTurn(payloadMessages)
        if explicit {
            var systemMarker: [String: Any] = ["type": "ephemeral"]
            if let explicitTTL { systemMarker["ttl"] = explicitTTL }
            payloadMessages[0]["content"] = [[
                "type": "text",
                "text": system,
                "cache_control": systemMarker,
            ] as [String: Any]]
            // A GPT-5.6-and-later write bills 1.25x, so a lone user turn that
            // will not be read back stays unmarked.
            let markTrailing = messages.count >= 2 || !AIModelDefaults.openAIBillsCacheWrites(model)
            if markTrailing,
               let last = payloadMessages.indices.last,
               let role = payloadMessages[last]["role"] as? String,
               role == "user",
               let text = payloadMessages[last]["content"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payloadMessages[last]["content"] = [[
                    "type": "text",
                    "text": text,
                    "cache_control": ["type": "ephemeral"],
                ] as [String: Any]]
            }
        }

        let opening = messages.first?.content ?? ""
        let material = lowered + "\u{1f}" + system + "\u{1f}" + opening
        let digest = SHA256.hash(data: Data(material.utf8))
        let sessionID = "flm-" + digest.map { String(format: "%02x", $0) }.joined()

        var payload: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "max_tokens": maxTokens,
            "session_id": sessionID,
        ]
        if let effort = route.effort { payload["reasoning_effort"] = effort }
        if jsonMode { payload["response_format"] = ["type": "json_object"] }
        if stream {
            payload["stream"] = true
            payload["usage"] = ["include": true]
        }
        // The account's data-policy switch, read with the route so this
        // builder stays synchronous; see `AIDataPolicy`.
        if route.deniesDataCollection {
            AIDataPolicy.applyDenyDataCollection(to: &payload)
        }
        // A model kept to one region's hosts: the store read their endpoints
        // with the route, and refuses the route when it could not.
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &payload, regionEndpointTags: route.regionEndpointTags)
        return try managedRequest(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            payload: payload,
            route: route
        )
    }

    private static func managedRequest(
        url: URL,
        payload: [String: Any],
        route: ResolvedAITextRoute
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        ManagedAI.rewrite(&request)
        // Operational attribution is the proxy's to read, and `rewrite` has
        // just cleared it from a request it sent straight to the router. What
        // the learner is working on is not the provider's business, so the
        // header goes back on only while the request is bound for ForeverLM.
        if request.url?.host == ManagedAI.baseURL.host {
            request.setValue(String(route.task.rawValue.prefix(80)), forHTTPHeaderField: "X-ForeverLM-Task")
        }
        return request
    }

    static func text(from data: Data) throws -> (json: [String: Any], text: String) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileSourceChatError.badResponse("The AI response was not valid JSON.")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MobileSourceChatError.badResponse("The AI response was not in the expected format.")
        }
        return (json, content)
    }

    /// Reject a billed answer when the provider reports that it served a model
    /// other than the one Settings resolved. Callers record usage first so the
    /// accounting ledger remains complete even though the answer is discarded.
    static func requireSelectedModel(
        _ json: [String: Any],
        route: ResolvedAITextRoute
    ) throws {
        try requireSelectedModel(report: AIUsageParser.report(from: json) ?? .empty, route: route)
    }

    static func requireSelectedModel(
        report: AIUsageReport,
        route: ResolvedAITextRoute
    ) throws {
        guard let served = report.rejectedSubstitution(fromRequested: route.model) else { return }
        throw MobileSourceChatError.badResponse(
            "The AI provider served \(served) instead of the selected model \(route.model). The response was rejected."
        )
    }
}

#if os(iOS)
struct PreparedMobilePaperNarration: Sendable {
    let text: String
    let sourceContentSignature: String
    let preparationSignature: String
}

/// iOS counterpart of the desktop Text-to-Speech Preparation task. Mobile
/// does not compile the desktop AI task catalog, but it uses the same prompt,
/// managed OpenRouter rail, task ledger label, and validated block-plan shape.
enum MobilePaperTextToSpeechPreparation {
    private struct Block: Sendable {
        let id: String
        let text: String
    }

    private struct Removal: Hashable, Sendable {
        let blockID: String
        let exactText: String
        let occurrence: Int
    }

    private struct Relocation: Sendable {
        let ids: [String]
        let insertAfterID: String
    }

    private struct ChunkPlan: Sendable {
        let adaptations: [(ids: [String], spokenText: String?)]
        let relocations: [Relocation]
        let removals: [Removal]
    }

    private struct IndexedChunkPlan: Sendable {
        let index: Int
        let plan: ChunkPlan
    }

    private static let maximumRequestCharacters = 48_000
    private static let maximumConcurrentRequests = 4
    private static let task = AITask.paperTextToSpeechPreparation.rawValue

    static func prepare(
        sourceID: String,
        sourceType: String,
        title: String,
        canonicalText: String,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PreparedMobilePaperNarration {
        let normalized = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MobileSourceChatError.badResponse("This source has no text to prepare for narration.")
        }
        guard ManagedAI.isSignedIn else {
            throw CloudArticleTTS.GenerationError.missingAPIKey
        }
        let route = try await MobileModelPreferenceStore.shared.resolve(.paperTextToSpeechPreparation)

        let sourceSignature = sha256(normalized)
        let preparationSignature = currentPreparationSignature(route: route)
        if let manifest = SyncedArticleAudioStore.loadManifestIgnoringChunks(sourceID: sourceID),
           manifest.usesCurrentNarration,
           manifest.sourceContentSignature == sourceSignature,
           manifest.narrationPreparationSignature == preparationSignature,
           let text = try? SyncedArticleAudioStore.loadSourceText(for: manifest),
           text.rangeOfCharacter(from: .alphanumerics) != nil {
            return PreparedMobilePaperNarration(
                text: text,
                sourceContentSignature: sourceSignature,
                preparationSignature: preparationSignature
            )
        }

        let blocks = normalized.components(separatedBy: .newlines).compactMap { raw -> String? in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.enumerated().map { offset, text in
            Block(id: String(format: "B%06d", offset + 1), text: text)
        }
        let chunks = requestChunks(blocks)
        guard !chunks.isEmpty else {
            throw MobileSourceChatError.badResponse("This source has no text to prepare for narration.")
        }

        await onProgress?(0, chunks.count)
        let chunkPlans = try await prepareChunks(
            route: route,
            sourceType: sourceType,
            title: title,
            chunks: chunks,
            onProgress: onProgress
        )
        var adaptations: [(ids: [String], spokenText: String?)] = []
        var relocations: [Relocation] = []
        var removals: [Removal] = []
        for plan in chunkPlans {
            adaptations.append(contentsOf: plan.adaptations)
            relocations.append(contentsOf: plan.relocations)
            removals.append(contentsOf: plan.removals)
        }

        let text = reconstruct(
            blocks: blocks,
            adaptations: adaptations,
            relocations: relocations,
            removals: removals
        )
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else {
            throw MobileSourceChatError.badResponse("Text-to-speech preparation returned no narratable text.")
        }
        return PreparedMobilePaperNarration(
            text: text,
            sourceContentSignature: sourceSignature,
            preparationSignature: preparationSignature
        )
    }

    static func currentPreparationSignature(route: ResolvedAITextRoute) -> String {
        PaperNarrationFilter.preparationContractPrefix + sha256([
            String(PaperNarrationFilter.version),
            route.provider,
            route.model,
            route.effort ?? "",
            Prompts.paperTextToSpeechPreparation,
        ].joined(separator: "\u{1F}"))
    }

    private static func prepareChunks(
        route: ResolvedAITextRoute,
        sourceType: String,
        title: String,
        chunks: [[Block]],
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)?
    ) async throws -> [ChunkPlan] {
        let initialCount = min(maximumConcurrentRequests, chunks.count)
        return try await withThrowingTaskGroup(of: IndexedChunkPlan.self) { group in
            for index in 0..<initialCount {
                let chunk = chunks[index]
                group.addTask {
                    IndexedChunkPlan(
                        index: index,
                        plan: try await prepareChunk(
                            route: route,
                            sourceType: sourceType,
                            title: title,
                            chunk: chunk,
                            index: index,
                            chunkCount: chunks.count
                        )
                    )
                }
            }

            var nextIndex = initialCount
            var completedCount = 0
            var results: [IndexedChunkPlan] = []
            results.reserveCapacity(chunks.count)
            while let result = try await group.next() {
                results.append(result)
                completedCount += 1
                await onProgress?(completedCount, chunks.count)

                if nextIndex < chunks.count {
                    let index = nextIndex
                    let chunk = chunks[index]
                    nextIndex += 1
                    group.addTask {
                        IndexedChunkPlan(
                            index: index,
                            plan: try await prepareChunk(
                                route: route,
                                sourceType: sourceType,
                                title: title,
                                chunk: chunk,
                                index: index,
                                chunkCount: chunks.count
                            )
                        )
                    }
                }
            }
            return results.sorted { $0.index < $1.index }.map(\.plan)
        }
    }

    private static func prepareChunk(
        route: ResolvedAITextRoute,
        sourceType: String,
        title: String,
        chunk: [Block],
        index: Int,
        chunkCount: Int
    ) async throws -> ChunkPlan {
        try Task.checkCancellation()
        let taggedBlocks = chunk.map { block in
            "{\"id\":\"\(block.id)\",\"text\":\"\(jsonEscaped(block.text))\"}"
        }.joined(separator: ",\n")
        var request = try MobileOpenRouterChat.request(
            route: route,
            system: Prompts.paperTextToSpeechPreparation,
            messages: [(role: "user", content: """
                SOURCE TYPE:
                \(sourceType)

                AUTHORITATIVE SOURCE TITLE:
                \(title)

                CHUNK CONTEXT:
                Chunk \(index + 1) of \(chunkCount). Block IDs are globally unique. Adaptations may use only IDs supplied below and may not cross chunk boundaries.

                BLOCKS JSON:
                [
                \(taggedBlocks)
                ]
                """)],
            // Match macOS: a long ordering window can legitimately need more
            // than 4k tokens of compact relocation/adaptation/citation JSON.
            maxTokens: 8_192,
            jsonMode: true
        )
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No response body."
            throw MobileSourceChatError.badResponse("Text-to-speech preparation failed: \(body)")
        }
        let parsed = try MobileOpenRouterChat.text(from: data)
        try MobileOpenRouterChat.requireSelectedModel(parsed.json, route: route)
        return try validatedPlan(parsed.text, blocks: chunk)
    }

    private static func requestChunks(_ blocks: [Block]) -> [[Block]] {
        var result: [[Block]] = []
        var current: [Block] = []
        var count = 0
        for block in blocks {
            let encodedCount = block.id.count * 2 + block.text.count + 24
            if !current.isEmpty, count + encodedCount > maximumRequestCharacters {
                result.append(current)
                current = []
                count = 0
            }
            current.append(block)
            count += encodedCount
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func validatedPlan(
        _ response: String,
        blocks: [Block]
    ) throws -> ChunkPlan {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            json = String(trimmed[firstBrace...lastBrace])
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawAdaptations = object["adaptations"] as? [[String: Any]] else {
            throw MobileSourceChatError.badResponse("Text-to-speech preparation returned invalid JSON.")
        }
        let indexByID = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
        var claimed = Set<String>()
        var accepted: [(ids: [String], spokenText: String?)] = []
        for raw in rawAdaptations {
            guard let ids = raw["blockIDs"] as? [String], !ids.isEmpty,
                  ids.allSatisfy({ indexByID[$0] != nil && !claimed.contains($0) }),
                  Set(ids).count == ids.count else { continue }
            let indices = ids.compactMap { indexByID[$0] }
            guard indices == indices.sorted(),
                  zip(indices, indices.dropFirst()).allSatisfy({ $0.1 == $0.0 + 1 }) else {
                continue
            }
            let rawSpoken = raw["spokenText"] as? String
            let spoken = rawSpoken?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard spoken == nil || (spoken!.count <= 1_200 && spoken!.rangeOfCharacter(from: .alphanumerics) != nil) else {
                continue
            }
            accepted.append((ids: ids, spokenText: spoken?.isEmpty == false ? spoken : nil))
            claimed.formUnion(ids)
        }

        var relocatedIDs = Set<String>()
        var relocationCandidates: [Relocation] = []
        let rawRelocations = object["relocations"] as? [[String: Any]] ?? []
        for raw in rawRelocations {
            guard let ids = raw["blockIDs"] as? [String],
                  !ids.isEmpty,
                  ids.allSatisfy({
                      indexByID[$0] != nil && !claimed.contains($0) && !relocatedIDs.contains($0)
                  }),
                  Set(ids).count == ids.count,
                  let anchor = raw["insertAfterBlockID"] as? String,
                  let anchorIndex = indexByID[anchor],
                  !claimed.contains(anchor),
                  !ids.contains(anchor) else { continue }
            let indices = ids.compactMap { indexByID[$0] }
            guard indices == indices.sorted(),
                  zip(indices, indices.dropFirst()).allSatisfy({ $0.1 == $0.0 + 1 }),
                  let finalMovedIndex = indices.last,
                  anchorIndex > finalMovedIndex else { continue }
            relocationCandidates.append(Relocation(ids: ids, insertAfterID: anchor))
            relocatedIDs.formUnion(ids)
        }
        let acceptedRelocations = relocationCandidates.filter {
            !relocatedIDs.contains($0.insertAfterID)
        }

        let textByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
        var acceptedRemovals = Set<Removal>()
        var acceptedRanges: [String: [Range<String.Index>]] = [:]
        let rawRemovals = object["removeText"] as? [[String: Any]] ?? []
        for raw in rawRemovals {
            guard let blockID = raw["blockID"] as? String,
                  !claimed.contains(blockID),
                  let exactText = raw["exactText"] as? String,
                  !exactText.isEmpty,
                  exactText.count <= 160,
                  let occurrence = raw["occurrence"] as? Int,
                  occurrence > 0,
                  let text = textByID[blockID],
                  let range = occurrenceRange(of: exactText, occurrence: occurrence, in: text),
                  !(acceptedRanges[blockID] ?? []).contains(where: { $0.overlaps(range) }) else {
                continue
            }
            acceptedRemovals.insert(
                Removal(blockID: blockID, exactText: exactText, occurrence: occurrence)
            )
            acceptedRanges[blockID, default: []].append(range)
        }
        return ChunkPlan(
            adaptations: accepted,
            relocations: acceptedRelocations,
            removals: acceptedRemovals.sorted {
                if $0.blockID != $1.blockID { return $0.blockID < $1.blockID }
                if $0.occurrence != $1.occurrence { return $0.occurrence < $1.occurrence }
                return $0.exactText < $1.exactText
            }
        )
    }

    private static func reconstruct(
        blocks: [Block],
        adaptations: [(ids: [String], spokenText: String?)],
        relocations: [Relocation],
        removals: [Removal]
    ) -> String {
        let byFirst = Dictionary(uniqueKeysWithValues: adaptations.compactMap { adaptation in
            adaptation.ids.first.map { ($0, adaptation) }
        })
        let relocatedIDs = Set(relocations.flatMap(\.ids))
        let relocationsByAnchor = Dictionary(grouping: relocations, by: \.insertAfterID)
        let indexByID = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let removalsByBlock = Dictionary(grouping: removals, by: \.blockID)
        var consumed = Set<String>()
        var output: [String] = []

        func appendUnadaptedBlock(_ block: Block) {
            let cleaned = applyingInlineDeletions(
                removalsByBlock[block.id] ?? [],
                to: block.text
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { output.append(cleaned) }
        }

        for block in blocks {
            if consumed.contains(block.id) || relocatedIDs.contains(block.id) { continue }
            if let adaptation = byFirst[block.id] {
                consumed.formUnion(adaptation.ids)
                if let spoken = adaptation.spokenText { output.append(spoken) }
            } else {
                appendUnadaptedBlock(block)
            }
            if let deferred = relocationsByAnchor[block.id] {
                for relocation in deferred.sorted(by: {
                    (indexByID[$0.ids[0]] ?? .max) < (indexByID[$1.ids[0]] ?? .max)
                }) {
                    for id in relocation.ids {
                        if let moved = blockByID[id] { appendUnadaptedBlock(moved) }
                    }
                }
            }
        }
        return output.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func applyingInlineDeletions(_ deletions: [Removal], to text: String) -> String {
        var ranges = deletions.compactMap {
            occurrenceRange(of: $0.exactText, occurrence: $0.occurrence, in: text)
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard !ranges.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        while !ranges.isEmpty {
            let range = ranges.removeFirst()
            guard range.lowerBound >= cursor else { continue }
            result.append(contentsOf: text[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])
        return result
    }

    private static func occurrenceRange(
        of needle: String,
        occurrence: Int,
        in text: String
    ) -> Range<String.Index>? {
        guard occurrence > 0, !needle.isEmpty else { return nil }
        var searchStart = text.startIndex
        for current in 1...occurrence {
            guard let range = text.range(of: needle, range: searchStart..<text.endIndex) else {
                return nil
            }
            if current == occurrence { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func jsonEscaped(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 4 else { return text }
        return String(encoded.dropFirst(2).dropLast(2))
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

enum MobileSourceChatError: LocalizedError {
    case missingSourceContext
    case missingAIProvider
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingSourceContext:
            return "This source does not have synced text yet. Open it in ForeverLM on your Mac so its text syncs to iCloud."
        case .missingAIProvider:
            return "Sign in with Apple to ask questions about a source."
        case .badResponse(let message):
            return message
        }
    }
}
