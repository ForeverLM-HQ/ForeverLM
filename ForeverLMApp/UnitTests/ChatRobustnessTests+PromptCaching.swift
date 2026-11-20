// Chat robustness tests: OpenRouter prompt caching and cache breakpoints.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

extension ChatRobustnessTests {
    // MARK: - OpenRouter prompt caching

    /// Prompt caching matches on a byte prefix, so the same logical payload must
    /// always encode to the same bytes. Swift dictionaries iterate in a
    /// per-process seeded order, and measurement showed plain
    /// `JSONSerialization` drifting between builds *within a single run* — not
    /// only across launches. Every drift is a guaranteed cache miss, which is
    /// why the request builders serialize with `.sortedKeys`.
    @Test("Chat request bodies encode deterministically")
    func chatRequestBodyEncodingIsStable() throws {
        // Nested dictionaries, as the tool catalogue carries on every turn.
        let payload: [String: Any] = [
            "model": "anthropic/claude-sonnet-5",
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": [["role": "system", "content": "stable head"]],
            "tools": (0..<12).map { i in
                [
                    "type": "function",
                    "function": [
                        "name": "tool_\(i)",
                        "description": "Tool \(i)",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "Search"] as [String: Any],
                                "mode": ["type": "string", "description": "Mode"] as [String: Any],
                                "source_ids": ["type": "array", "description": "IDs"] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any]
            },
        ]

        let baseline = try AIService.stableJSONBody(payload)
        for _ in 0..<200 {
            #expect(try AIService.stableJSONBody(payload) == baseline)
        }
    }

    /// The breakpoint must sit at the end of the stable head. Marking the
    /// volatile tail instead would cache a prefix that changes every turn,
    /// which never hits and pays the write cost each time.
    @Test("cache_control marks the stable head, never the volatile tail")
    func cacheBreakpointMarksStableHeadOnly() throws {
        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": [
                    ["type": "text", "text": "stable head"] as [String: Any],
                    ["type": "text", "text": "volatile tail"] as [String: Any],
                ],
            ],
            ["role": "user", "content": "question"],
        ]
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints(messages, systemTTL: "1h")
        let blocks = try #require(marked[0]["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"] as? String == "stable head")
        #expect(blocks[0]["cache_control"] != nil)
        // The tail must stay unmarked, or the cached prefix moves every turn.
        #expect(blocks[1]["cache_control"] == nil)
    }

    // MARK: - Budget-truncated heads must not be cached

    /// Emergency budget truncation cuts the system head at
    /// `inputCharacterBudget - turnsSize`, and that boundary moves every turn.
    /// Marking it is worse than leaving it alone: the write bills at 1.25x
    /// (5-minute TTL) or 2x (1-hour) and is never read back, against 1x for an
    /// unmarked prefix.
    @Test("A budget-truncated system head carries no cache breakpoint")
    func truncatedSystemHeadIsNotMarked() throws {
        let stable = "instructions plus attached source text"
        let truncated = stable + AIService.budgetSourceTruncationNote

        #expect(AIService.systemPromptIsCacheable(stable))
        #expect(!AIService.systemPromptIsCacheable(truncated))
    }

    /// The head is whatever a breakpoint would end on: block 0 of a pre-split
    /// system message, or the whole string when there is no split.
    @Test("The OpenAI-style stable head is read from the first system block")
    func openAIStyleStableHeadExtraction() {
        let split: [[String: Any]] = [[
            "role": "system",
            "content": [
                ["type": "text", "text": "stable head"] as [String: Any],
                ["type": "text", "text": "volatile tail"] as [String: Any],
            ],
        ]]
        #expect(AIService.openAIStyleStableSystemHead(split) == "stable head")

        let plain: [[String: Any]] = [["role": "system", "content": "just the head"]]
        #expect(AIService.openAIStyleStableSystemHead(plain) == "just the head")

        // No system message is not a truncated one — nothing was cut.
        let none: [[String: Any]] = [["role": "user", "content": "question"]]
        #expect(AIService.openAIStyleStableSystemHead(none).isEmpty)
        #expect(AIService.systemPromptIsCacheable(AIService.openAIStyleStableSystemHead(none)))
    }

    /// Sticky routing is free and still wanted on a truncated request; only the
    /// billable breakpoints are withheld.
    @Test("OpenRouter withholds breakpoints for a truncated head but keeps session_id")
    func openRouterSkipsBreakpointsForTruncatedHead() throws {
        func payload(system: String) -> [String: Any] {
            [
                "model": "anthropic/claude-sonnet-4-6",
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": "question"],
                ] as [[String: Any]],
            ]
        }

        var healthy = payload(system: "instructions plus source")
        AIService.applyOpenRouterPayloadExtras(&healthy, provider: .openRouter)
        let healthyMessages = try #require(healthy["messages"] as? [[String: Any]])
        let healthyBlocks = try #require(healthyMessages[0]["content"] as? [[String: Any]])
        #expect(healthyBlocks[0]["cache_control"] != nil)
        #expect(healthy["session_id"] != nil)

        var truncated = payload(
            system: "instructions plus source" + AIService.budgetSourceTruncationNote
        )
        AIService.applyOpenRouterPayloadExtras(&truncated, provider: .openRouter)
        let truncatedMessages = try #require(truncated["messages"] as? [[String: Any]])
        // Left in its original string shape — no marker anywhere in the request.
        #expect(truncatedMessages[0]["content"] as? String != nil)
        #expect(truncatedMessages.allSatisfy { message in
            (message["content"] as? [[String: Any]])?
                .allSatisfy { $0["cache_control"] == nil } ?? true
        })
        #expect(truncated["session_id"] != nil)
    }

    /// Prompt caching matches on a byte prefix and Swift dictionaries iterate in
    /// a per-process seeded order, so request bodies must encode deterministically
    /// or every cache lookup misses after a relaunch.
    @Test("Request bodies serialize with sorted keys")
    func requestBodiesAreDeterministic() throws {
        let payload: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 16,
            "system": "head",
            "beta": true,
        ]
        let encoded = try #require(String(data: try AIService.stableJSONBody(payload), encoding: .utf8))
        let keyOrder = ["beta", "max_tokens", "model", "system"].map { "\"\($0)\":" }
        var cursor = encoded.startIndex
        for key in keyOrder {
            let found = try #require(encoded.range(of: key, range: cursor..<encoded.endIndex))
            cursor = found.upperBound
        }
    }

    @Test("Explicit cache policy matches OpenRouter's documented model capabilities")
    func openRouterExplicitCacheControlGate() {
        #expect(AIService.openRouterModelNeedsExplicitCacheControl("anthropic/claude-sonnet-4-6"))
        #expect(AIService.openRouterModelNeedsExplicitCacheControl("google/gemini-3.1-pro-preview"))
        #expect(AIService.openRouterModelNeedsExplicitCacheControl("qwen/qwen3-max"))
        #expect(AIService.openRouterModelNeedsExplicitCacheControl("deepseek/deepseek-v3.2"))
        // OpenRouter explicitly excludes arbitrary Qwen snapshots/models.
        #expect(!AIService.openRouterModelNeedsExplicitCacheControl("qwen/qwen3-32b"))
        #expect(!AIService.openRouterModelNeedsExplicitCacheControl("qwen/qwen3-235b-a22b-2507"))
        // Automatic-caching providers must not get annotated payloads.
        #expect(!AIService.openRouterModelNeedsExplicitCacheControl("deepseek/deepseek-v4-flash"))
        #expect(!AIService.openRouterModelNeedsExplicitCacheControl("openai/gpt-oss-120b"))
        #expect(!AIService.openRouterModelNeedsExplicitCacheControl("moonshotai/kimi-k3"))
    }

    @Test("Every offered text model gets deterministic OpenRouter cache affinity")
    func everyCatalogModelGetsCacheAffinity() throws {
        for entry in AIModelCatalog.makerGroups.flatMap(\.entries) {
            let slug = OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID)
            var payload: [String: Any] = [
                "model": slug,
                "messages": [
                    ["role": "system", "content": "stable instructions and source"],
                    ["role": "user", "content": "opening question"],
                ] as [[String: Any]],
            ]
            AIService.applyOpenRouterPayloadExtras(&payload, provider: .openRouter)
            let sessionID = try #require(payload["session_id"] as? String)
            #expect(sessionID.hasPrefix("flm-"), "Missing cache affinity for \(slug)")
            #expect(sessionID.count <= 256)
        }
    }

    @Test("Cache affinity survives volatile tail and later-turn changes")
    func cacheAffinityTracksConversationStableHead() throws {
        func messages(tail: String, followUp: String) -> [[String: Any]] {
            [
                [
                    "role": "system",
                    "content": [
                        ["type": "text", "text": "stable instructions and source"],
                        ["type": "text", "text": tail],
                    ] as [[String: Any]],
                ],
                ["role": "user", "content": "opening question"],
                ["role": "assistant", "content": "first answer"],
                ["role": "user", "content": followUp],
            ]
        }

        let first = try #require(AIService.openRouterPromptCacheSessionID(
            model: "openai/gpt-5.6-sol",
            messages: messages(tail: "digest one", followUp: "follow-up one")
        ))
        let later = try #require(AIService.openRouterPromptCacheSessionID(
            model: "openai/gpt-5.6-sol",
            messages: messages(tail: "digest two", followUp: "follow-up two")
        ))
        #expect(first == later)

        var changedOpening = messages(tail: "digest two", followUp: "follow-up two")
        changedOpening[1]["content"] = "a different conversation"
        let different = try #require(AIService.openRouterPromptCacheSessionID(
            model: "openai/gpt-5.6-sol",
            messages: changedOpening
        ))
        #expect(first != different)
    }

    @Test("Central OpenRouter policy marks explicit models and leaves automatic models native")
    func centralOpenRouterCachePolicy() throws {
        let baseMessages: [[String: Any]] = [
            [
                "role": "system",
                "content": [
                    ["type": "text", "text": "stable head"],
                    ["type": "text", "text": "volatile tail"],
                ] as [[String: Any]],
            ],
            ["role": "user", "content": "question"],
        ]

        var claude: [String: Any] = ["model": "anthropic/claude-sonnet-5", "messages": baseMessages]
        AIService.applyOpenRouterPayloadExtras(&claude, provider: .openRouter)
        let claudeMessages = try #require(claude["messages"] as? [[String: Any]])
        let systemBlocks = try #require(claudeMessages[0]["content"] as? [[String: Any]])
        // The tail leaves the system message for every model, so the cached
        // system block is the whole system message.
        #expect(systemBlocks.count == 1)
        let systemMarker = try #require(systemBlocks[0]["cache_control"] as? [String: Any])
        #expect(systemMarker["ttl"] as? String == "1h")
        let claudeTail = try #require(claudeMessages[1]["content"] as? [[String: Any]])
        #expect(claudeTail.map { $0["text"] as? String } == [AIService.volatileContextOpening, "volatile tail", AIService.volatileContextClosing])
        #expect(claudeTail[1]["cache_control"] == nil)
        let lastBlocks = try #require(claudeMessages[2]["content"] as? [[String: Any]])
        #expect(lastBlocks.last?["cache_control"] != nil)

        var gemini: [String: Any] = ["model": "google/gemini-3.1-pro-preview", "messages": baseMessages]
        AIService.applyOpenRouterPayloadExtras(&gemini, provider: .openRouter)
        let geminiMessages = try #require(gemini["messages"] as? [[String: Any]])
        let geminiBlocks = try #require(geminiMessages[0]["content"] as? [[String: Any]])
        #expect(geminiBlocks.count == 1)
        #expect(geminiBlocks[0]["text"] as? String == "stable head")
        let geminiMarker = try #require(geminiBlocks[0]["cache_control"] as? [String: Any])
        #expect(geminiMarker["ttl"] == nil)
        #expect(geminiMessages[1]["role"] as? String == "user")
        let geminiVolatile = try #require(geminiMessages[1]["content"] as? [[String: Any]])
        #expect(geminiVolatile.count == 3)
        #expect(geminiVolatile[1]["text"] as? String == "volatile tail")
        #expect(geminiVolatile[1]["cache_control"] == nil)
        #expect(geminiMessages[2]["role"] as? String == "user")

        var automatic: [String: Any] = ["model": "deepseek/deepseek-v4-pro", "messages": baseMessages]
        AIService.applyOpenRouterPayloadExtras(&automatic, provider: .openRouter)
        let automaticMessages = try #require(automatic["messages"] as? [[String: Any]])
        let automaticBlocks = try #require(automaticMessages[0]["content"] as? [[String: Any]])
        #expect(automaticBlocks.allSatisfy { $0["cache_control"] == nil })
        // An automatic-cache model reads the same byte prefix, so its tail is
        // moved behind the history too, and nothing is marked.
        #expect(automaticBlocks.map { $0["text"] as? String } == ["stable head"])
        #expect(automaticMessages.count == 3)
        #expect(automaticMessages[2]["content"] as? String == "question")
        #expect(automatic["session_id"] != nil)
    }

    @Test("The volatile tail sits behind the history for every model, so the history is a stable prefix")
    func volatileTailFollowsHistoryForEveryModel() throws {
        func turn(tail: String, upTo count: Int) -> [[String: Any]] {
            var messages: [[String: Any]] = [
                [
                    "role": "system",
                    "content": [
                        ["type": "text", "text": "stable head"],
                        ["type": "text", "text": tail],
                    ] as [[String: Any]],
                ],
                ["role": "user", "content": "question one"],
                ["role": "assistant", "content": "answer one"],
                ["role": "user", "content": "question two"],
                ["role": "assistant", "content": "answer two"],
                ["role": "user", "content": "question three"],
            ]
            messages.removeLast(messages.count - (count + 1))
            return messages
        }

        for model in [
            "anthropic/claude-sonnet-5", "google/gemini-3.1-pro-preview", "openai/gpt-5.6-sol",
            "deepseek/deepseek-v4-pro", "z-ai/glm-5.3-flash",
        ] {
            func request(_ messages: [[String: Any]]) throws -> [[String: Any]] {
                var payload: [String: Any] = ["model": model, "messages": messages]
                AIService.applyOpenRouterPayloadExtras(&payload, provider: .openRouter)
                return try #require(payload["messages"] as? [[String: Any]])
            }
            // Turn two and turn three differ only in the tail and the newer turns.
            let second = try request(turn(tail: "clock 10:01", upTo: 3))
            let third = try request(turn(tail: "clock 10:02", upTo: 5))

            // Nothing volatile remains in the system message ...
            let system = try #require(second[0]["content"] as? [[String: Any]])
            #expect(system.map { $0["text"] as? String } == ["stable head"], "\(model)")
            // ... the tail precedes the learner's newest message ...
            let secondTail = try #require(second[second.count - 2]["content"] as? [[String: Any]])
            #expect(secondTail.dropFirst().first?["text"] as? String == "clock 10:01", "\(model)")
            // ... and the earlier conversation is byte-identical between turns,
            // so a cached prefix covers it.
            //
            // Compared by role and text: a cache breakpoint on the message ahead
            // of the tail (Anthropic) wraps that message's string in a marked
            // block, and the marker moves forward each turn like the trailing
            // one does. Neither is part of what the provider's cache hashes.
            func content(_ message: [String: Any]) -> [String: String] {
                let text: String
                if let string = message["content"] as? String {
                    text = string
                } else {
                    text = (message["content"] as? [[String: Any]] ?? [])
                        .compactMap { $0["text"] as? String }.joined(separator: "\u{1f}")
                }
                return ["role": message["role"] as? String ?? "", "text": text]
            }
            let sharedCount = 3  // system, question one, answer one
            let secondBytes = try AIService.stableJSONBody(["m": second.prefix(sharedCount).map(content)])
            let thirdBytes = try AIService.stableJSONBody(["m": third.prefix(sharedCount).map(content)])
            #expect(secondBytes == thirdBytes, "\(model) rewrites its history when the tail changes")
        }
    }

    @Test("Within one turn's tool rounds the tail stays put and the prefix only grows")
    func volatileTailIsStableAcrossToolRounds() throws {
        func request(extra: [[String: Any]]) throws -> [[String: Any]] {
            var messages: [[String: Any]] = [
                [
                    "role": "system",
                    "content": [
                        ["type": "text", "text": "stable head"],
                        ["type": "text", "text": "clock 10:01"],
                    ] as [[String: Any]],
                ],
                ["role": "user", "content": "find the figure"],
            ]
            messages.append(contentsOf: extra)
            var payload: [String: Any] = [
                "model": "openai/gpt-5.6-sol",
                "messages": messages,
                "tools": [["type": "function", "function": ["name": "t"]]] as [[String: Any]],
            ]
            AIService.applyOpenRouterPayloadExtras(&payload, provider: .openRouter)
            return try #require(payload["messages"] as? [[String: Any]])
        }
        let first = try request(extra: [])
        let second = try request(extra: [
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1"]]],
            ["role": "tool", "tool_call_id": "c1", "content": "result"],
        ])
        // system, tail, learner message — the same three in both rounds.
        let firstBytes = try AIService.stableJSONBody(["m": Array(first.prefix(2))])
        let secondBytes = try AIService.stableJSONBody(["m": Array(second.prefix(2))])
        #expect(firstBytes == secondBytes)
        #expect(second.count == 5)
        #expect(second[2]["role"] as? String == "user")
    }

    @Test("GPT-5.6 and later are cached with explicit breakpoints; older GPT and gpt-oss are not")
    func openAIBilledCacheWritesGetExplicitBreakpoints() {
        for slug in [
            "openai/gpt-5.6-sol", "openai/gpt-5.6-luna", "openai/gpt-5.6-sol-pro",
            "openai/gpt-6-luna", "openai/gpt-6-sol-pro", "openai/gpt-6.1-sol", "openai/gpt-6-astra",
        ] {
            #expect(AIService.openRouterCachePolicy(for: slug) == .explicitBreakpoints(ttl: nil), "\(slug)")
            // OpenRouter drops a cache_control ttl toward OpenAI, so none is sent.
            #expect(!AIService.openRouterModelSupportsCacheTTL(slug), "\(slug)")
        }
        for slug in [
            "openai/gpt-5.5", "openai/gpt-5.5-pro", "openai/gpt-5-nano", "openai/gpt-4o-mini",
            "openai/gpt-oss-120b", "openai/gpt-oss-20b", "openai/gpt-chat-latest",
        ] {
            #expect(AIService.openRouterCachePolicy(for: slug) == .implicit, "\(slug)")
        }
        #expect(AIModelDefaults.openAIMinorVersion(of: "openai/gpt-5.6-sol") == 6)
        #expect(AIModelDefaults.openAIMinorVersion(of: "gpt-6-astra") == nil)
        #expect(AIModelDefaults.openAIMinorVersion(of: "openai/gpt-oss-120b") == nil)
    }

    @Test("A GPT-5.6 one-shot marks only its instruction head; a conversation or tool round also marks its tail")
    func openAIOneShotAvoidsPayingToCacheItsDocument() throws {
        func marked(_ payload: [String: Any]) throws -> (system: Bool, last: Bool) {
            var payload = payload
            AIService.applyOpenRouterPayloadExtras(&payload, provider: .openRouter)
            let messages = try #require(payload["messages"] as? [[String: Any]])
            let systemBlocks = try #require(messages[0]["content"] as? [[String: Any]])
            let lastBlocks = messages.last?["content"] as? [[String: Any]]
            return (
                systemBlocks[0]["cache_control"] != nil,
                lastBlocks?.contains { $0["cache_control"] != nil } ?? false
            )
        }
        let oneShot: [String: Any] = [
            "model": "openai/gpt-5.6-luna",
            "messages": [
                ["role": "system", "content": "instructions"],
                ["role": "user", "content": "one document, read once"],
            ] as [[String: Any]],
        ]
        let single = try marked(oneShot)
        #expect(single.system)
        #expect(!single.last)

        var conversation = oneShot
        conversation["messages"] = [
            ["role": "system", "content": "instructions"],
            ["role": "user", "content": "first"],
            ["role": "assistant", "content": "answer"],
            ["role": "user", "content": "second"],
        ] as [[String: Any]]
        let multi = try marked(conversation)
        #expect(multi.system)
        #expect(multi.last)

        var tooled = oneShot
        tooled["tools"] = [["type": "function", "function": ["name": "t"]]] as [[String: Any]]
        let withTools = try marked(tooled)
        #expect(withTools.system)
        #expect(withTools.last)

        // Anthropic keeps marking the lone user turn, as it always has.
        var claude = oneShot
        claude["model"] = "anthropic/claude-sonnet-5"
        let anthropic = try marked(claude)
        #expect(anthropic.system)
        #expect(anthropic.last)
    }

    @Test("A complete paper reaches the final cache-marked OpenRouter request unchanged")
    @MainActor
    func completePaperIsInFinalCachedPrefix() async throws {
        let paper = "PAPER-TEXT-START\n"
            + String(repeating: "A realistic extracted paper paragraph with methods, evidence, and limitations. ", count: 500)
            + "\nPAPER-TEXT-END"
        let initial = ReviewSessionManager.initialPayloadForTesting(
            mode: .assistant,
            topic: "Cache contract paper",
            hasAttachedSource: true,
            sourceContext: paper
        )
        let firstTurns = initial.messages.map { message -> AIChatTurn in
            message.role == "assistant"
                ? .assistant(text: message.content, toolCalls: [])
                : .user(message.content)
        }
        let service = AIService()

        let firstPayload = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter,
            system: initial.system,
            volatileSystem: "\n\nVOLATILE-TURN-A",
            turns: firstTurns,
            tools: [],
            maxTokens: 500,
            model: "anthropic/claude-sonnet-5",
            effort: nil
        )
        // Inspect a round-trip of the exact deterministic bytes production puts
        // in URLRequest.httpBody, not the pre-serialization dictionaries.
        let firstData = try AIService.stableJSONBody(firstPayload)
        let firstWire = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let firstMessages = try #require(firstWire["messages"] as? [[String: Any]])
        let firstSystemBlocks = try #require(firstMessages[0]["content"] as? [[String: Any]])
        let firstStable = try #require(firstSystemBlocks[0]["text"] as? String)
        #expect(firstStable.contains("PAPER-TEXT-START"))
        #expect(firstStable.contains("PAPER-TEXT-END"))
        #expect(firstStable.contains(paper))
        let marker = try #require(firstSystemBlocks[0]["cache_control"] as? [String: Any])
        #expect(marker["type"] as? String == "ephemeral")
        #expect(marker["ttl"] as? String == "1h")
        // The tail is a message of its own in front of the learner's turn, so
        // the cached system block is the whole system message.
        #expect(firstSystemBlocks.count == 1)
        let firstTail = try #require(firstMessages[1]["content"] as? [[String: Any]])
        #expect(firstTail[1]["text"] as? String == "\n\nVOLATILE-TURN-A")
        #expect(firstTail[1]["cache_control"] == nil)

        let laterPayload = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter,
            system: initial.system,
            volatileSystem: "\n\nVOLATILE-TURN-B",
            turns: firstTurns + [
                .assistant(text: "First answer", toolCalls: []),
                .user("Follow-up about the evidence"),
            ],
            tools: [],
            maxTokens: 500,
            model: "anthropic/claude-sonnet-5",
            effort: nil
        )
        let laterMessages = try #require(laterPayload["messages"] as? [[String: Any]])
        let laterSystemBlocks = try #require(laterMessages[0]["content"] as? [[String: Any]])
        #expect(laterSystemBlocks[0]["text"] as? String == firstStable)
        #expect((laterPayload["session_id"] as? String) == (firstPayload["session_id"] as? String))
    }

    @Test("Anthropic caches the instructions and the source text apart, so a retrieval rewrites only the text")
    @MainActor
    func anthropicSourceTextIsItsOwnCachedBlock() async throws {
        let header = ReviewSessionManager.GenerationSystemPrompt.sourceTextHeader
        let head = "INSTRUCTIONS-HEAD"
        let turns: [AIChatTurn] = [
            .user("First question"),
            .assistant(text: "First answer", toolCalls: []),
            .user("Second question"),
        ]
        let service = AIService()
        func payload(sources: String, volatile: String) async -> [String: Any] {
            await service.makeOpenAIStyleToolPayload(
                provider: .openRouter,
                system: head,
                sourceSystem: sources,
                volatileSystem: volatile,
                turns: turns,
                tools: [],
                maxTokens: 500,
                model: "anthropic/claude-sonnet-5",
                effort: nil
            )
        }
        let before = await payload(sources: header + "EXCERPT-ONE", volatile: "\n\nVOLATILE-A")
        // A retrieval appends to the source text; the tail changes every turn.
        let after = await payload(
            sources: header + "EXCERPT-ONE" + ReviewSessionManager.sourceBlockSeparator + "EXCERPT-TWO",
            volatile: "\n\nVOLATILE-B"
        )

        let beforeMessages = try #require(before["messages"] as? [[String: Any]])
        let afterMessages = try #require(after["messages"] as? [[String: Any]])
        let beforeSystem = try #require(beforeMessages[0]["content"] as? [[String: Any]])
        let afterSystem = try #require(afterMessages[0]["content"] as? [[String: Any]])

        // Two cached system blocks, the instructions then the text, both on the
        // long ttl, and the tail nowhere in the system message.
        #expect(beforeSystem.count == 2)
        #expect(beforeSystem[0]["text"] as? String == head)
        #expect((beforeSystem[0]["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")
        #expect((beforeSystem[1]["text"] as? String)?.hasSuffix("EXCERPT-ONE") == true)
        #expect((beforeSystem[1]["cache_control"] as? [String: Any])?["ttl"] as? String == "1h")

        // What a retrieval must not change: the instructions block, byte for
        // byte, and the session id sticky routing keys on.
        #expect(afterSystem[0]["text"] as? String == beforeSystem[0]["text"] as? String)
        #expect(afterSystem[1]["text"] as? String != beforeSystem[1]["text"] as? String)
        #expect((after["session_id"] as? String) == (before["session_id"] as? String))

        // system, question 1, answer 1, tail, question 2. The answer ends the
        // history the next turn repeats, so it carries a breakpoint on the
        // default ttl; the tail does not; the learner's newest message does.
        #expect(afterMessages.count == 5)
        let answer = try #require(afterMessages[2]["content"] as? [[String: Any]])
        let answerMarker = try #require(answer.last?["cache_control"] as? [String: Any])
        #expect(answerMarker["ttl"] == nil)
        let tail = try #require(afterMessages[3]["content"] as? [[String: Any]])
        #expect(tail[1]["text"] as? String == "\n\nVOLATILE-B")
        #expect(tail[1]["cache_control"] == nil)
        let newest = try #require(afterMessages[4]["content"] as? [[String: Any]])
        #expect(newest.last?["cache_control"] != nil)
    }

    @Test("A provider that does not cache by block keeps the source text in the one system block")
    @MainActor
    func nonAnthropicSourceTextStaysInTheStableBlock() async throws {
        let header = ReviewSessionManager.GenerationSystemPrompt.sourceTextHeader
        let payload = await AIService().makeOpenAIStyleToolPayload(
            provider: .openRouter,
            system: "INSTRUCTIONS-HEAD",
            sourceSystem: header + "THE-PAPER",
            volatileSystem: "CHANGING",
            turns: [.user("Opening learner question")],
            tools: [],
            maxTokens: 200,
            model: "google/gemini-3.5-flash",
            effort: nil
        )
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["text"] as? String == "INSTRUCTIONS-HEAD" + header + "THE-PAPER")
        // No history breakpoint off Anthropic: the one before the tail is for
        // the family whose caching is documented to take several.
        #expect(messages.count == 3)
        #expect(messages[1]["content"] is [[String: Any]])
    }

    @Test("The per-turn tail leaves the instructions and the source text in the system message")
    func volatileTailMoveKeepsTheSourceBlock() throws {
        let header = ReviewSessionManager.GenerationSystemPrompt.sourceTextHeader
        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": [
                    ["type": "text", "text": "HEAD"] as [String: Any],
                    ["type": "text", "text": header + "SOURCES"] as [String: Any],
                    ["type": "text", "text": "TAIL"] as [String: Any],
                ],
            ],
            ["role": "user", "content": "one"],
            ["role": "assistant", "content": "two"],
            ["role": "user", "content": "three"],
        ]
        let moved = AIService.openRouterMessagesWithVolatileContext(messages)
        let system = try #require(moved.messages[0]["content"] as? [[String: Any]])
        #expect(system.map { $0["text"] as? String } == ["HEAD", header + "SOURCES"])
        #expect(moved.tailIndex == 3)
        let tail = try #require(moved.messages[3]["content"] as? [[String: Any]])
        // Framed, so a provider that joins it to the learner's message after
        // it does not read it as the learner's latest message.
        #expect(tail.map { $0["text"] as? String } == [
            AIService.volatileContextOpening, "TAIL", AIService.volatileContextClosing,
        ])
        #expect(moved.messages[4]["content"] as? String == "three")

        // A system message with no tail is left alone, and reports none.
        let alone = AIService.openRouterMessagesWithVolatileContext([
            ["role": "system", "content": [
                ["type": "text", "text": "HEAD"] as [String: Any],
                ["type": "text", "text": header + "SOURCES"] as [String: Any],
            ]],
            ["role": "user", "content": "one"],
        ])
        #expect(alone.tailIndex == nil)
        #expect(alone.messages.count == 2)
    }

    @Test("The per-turn tail stays in front of the learner's message for every tool round of the turn")
    func volatileTailStaysPutAcrossToolRounds() throws {
        let system: [String: Any] = ["role": "system", "content": [
            ["type": "text", "text": "HEAD"] as [String: Any],
            ["type": "text", "text": "TAIL"] as [String: Any],
        ]]
        let toolRound: [[String: Any]] = [
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function",
                "function": ["name": "search_sources_semantic", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "c1", "content": "results"],
        ]
        let base: [[String: Any]] = [system, ["role": "user", "content": "ask"]] + toolRound

        // The pictures of a tool result arrive as a user message right after
        // the tool message: never the learner's, so the tail does not move.
        let pictured = AIService.openRouterMessagesWithVolatileContext(
            base + [["role": "user", "content": [["type": "text", "text": "picture"]]]]
        )
        #expect(pictured.tailIndex == 1)
        #expect(pictured.messages[2]["content"] as? String == "ask")

        // A nudge after a rejected reply looks like a learner message; the
        // tool loop names the learner's message, and the tail stays there.
        let nudged = base + [
            ["role": "assistant", "content": "I'll search now."],
            ["role": "user", "content": "Call the tool now."],
        ]
        #expect(AIService.openRouterMessagesWithVolatileContext(nudged).tailIndex == 5)
        let pinned = AIService.openRouterMessagesWithVolatileContext(nudged, learnerMessageIndex: 1)
        #expect(pinned.tailIndex == 1)
        #expect(pinned.messages[2]["content"] as? String == "ask")
        #expect(pinned.messages.last?["content"] as? String == "Call the tool now.")

        // An index that names no user message falls back to the default.
        #expect(AIService.openRouterMessagesWithVolatileContext(nudged, learnerMessageIndex: 2).tailIndex == 5)
    }

    @Test("A learner turn's message index counts tool results and picture follow-ups")
    func learnerTurnMessageIndex() {
        let picture = AIChatImage(data: Data([0]), mediaType: "image/png")
        let turns: [AIChatTurn] = [
            .user("one"),
            .assistant(text: "", toolCalls: [AIToolCallRequest(id: "a", name: "t", argumentsJSON: "{}")]),
            .toolResults([
                AIToolResultPayload(callID: "a", toolName: "t", text: "r", isError: false, images: [picture]),
                AIToolResultPayload(callID: "b", toolName: "t", text: "r", isError: false),
            ]),
            .assistant(text: "answer", toolCalls: []),
            .user("two"),
        ]
        // system, one, assistant, tool a, tool b, picture follow-up, answer, two
        #expect(AIService.openAIStyleMessageIndex(ofLearnerTurn: 4, in: turns) == 7)
        #expect(AIService.openAIStyleMessageIndex(ofLearnerTurn: 0, in: turns) == 1)
        #expect(AIService.openAIStyleMessageIndex(ofLearnerTurn: 3, in: turns) == nil)
        #expect(AIService.openAIStyleMessageIndex(ofLearnerTurn: 9, in: turns) == nil)
        #expect(AIService.openAIStyleToolMessages(system: "S", turns: turns)[7]["content"] as? String == "two")
    }

    @Test("A retry directive ends the request instead of changing the per-turn tail")
    @MainActor
    func retryDirectiveEndsTheRequest() {
        let afterLearner = ReviewSessionManager.nativeTurns([.user("ask")], endingWith: "Answer now.")
        #expect(afterLearner.count == 1)
        if case .user(let text, _) = afterLearner[0] { #expect(text == "ask\n\nAnswer now.") } else { Issue.record("not a user turn") }

        let afterTools = ReviewSessionManager.nativeTurns(
            [.user("ask"), .toolResults([AIToolResultPayload(callID: "a", toolName: "t", text: "r", isError: false)])],
            endingWith: "Answer now."
        )
        #expect(afterTools.count == 3)
        if case .user(let text, _) = afterTools[2] { #expect(text == "Answer now.") } else { Issue.record("not a user turn") }
    }

    @Test("Gemini moves changing context after the immutable cached paper instruction")
    @MainActor
    func geminiVolatileContextFollowsCachedPaper() async throws {
        let service = AIService()
        let payload = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter,
            system: "STABLE-PAPER-START\nFull extracted paper text.\nSTABLE-PAPER-END",
            volatileSystem: "CHANGING-HISTORY-DIGEST",
            turns: [.user("Opening learner question")],
            tools: [],
            maxTokens: 200,
            model: "google/gemini-3.5-flash",
            effort: nil
        )

        let messages = try #require(payload["messages"] as? [[String: Any]])
        let systemBlocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(systemBlocks.count == 1)
        #expect((systemBlocks[0]["text"] as? String)?.contains("STABLE-PAPER-END") == true)
        #expect(systemBlocks[0]["cache_control"] != nil)

        #expect(messages[1]["role"] as? String == "user")
        let dynamicBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(dynamicBlocks[1]["text"] as? String == "CHANGING-HISTORY-DIGEST")
        #expect(dynamicBlocks[1]["cache_control"] == nil)
        let learnerBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(learnerBlocks[0]["text"] as? String == "Opening learner question")
        #expect(learnerBlocks[0]["cache_control"] != nil)
    }

    @Test("Every offered model keeps the complete paper as its leading stable prefix")
    @MainActor
    func everyCatalogModelKeepsPaperPrefix() async throws {
        let paper = "CATALOG-PAPER-START\n"
            + String(repeating: "Stable extracted evidence and methods. ", count: 300)
            + "\nCATALOG-PAPER-END"
        let service = AIService()

        for entry in AIModelCatalog.allEntries {
            let first = await service.makeOpenAIStyleToolPayload(
                provider: entry.provider,
                system: paper,
                volatileSystem: "DYNAMIC-A",
                turns: [.user("Opening question")],
                tools: [],
                maxTokens: 100,
                model: entry.modelID,
                effort: nil
            )
            let later = await service.makeOpenAIStyleToolPayload(
                provider: entry.provider,
                system: paper,
                volatileSystem: "DYNAMIC-B",
                turns: [
                    .user("Opening question"),
                    .assistant(text: "First answer", toolCalls: []),
                    .user("Follow-up"),
                ],
                tools: [],
                maxTokens: 100,
                model: entry.modelID,
                effort: nil
            )

            let firstMessages = try #require(first["messages"] as? [[String: Any]])
            let laterMessages = try #require(later["messages"] as? [[String: Any]])
            let firstBlocks = try #require(firstMessages[0]["content"] as? [[String: Any]])
            let laterBlocks = try #require(laterMessages[0]["content"] as? [[String: Any]])
            #expect(firstBlocks[0]["text"] as? String == paper, "Paper changed for \(entry.modelID)")
            #expect(laterBlocks[0]["text"] as? String == paper, "Paper changed on follow-up for \(entry.modelID)")
            #expect((first["session_id"] as? String) == (later["session_id"] as? String), "Affinity changed for \(entry.modelID)")
        }
    }

    @Test("In-app live diagnostic sends one unchanged cache-marked paper prefix")
    func promptCacheDiagnosticPayloadContract() throws {
        let firstData = try PromptCacheDiagnostic.requestBody(
            runID: "fixed-run",
            assistantAnswer: nil
        )
        let secondData = try PromptCacheDiagnostic.requestBody(
            runID: "fixed-run",
            assistantAnswer: "Paper acknowledged."
        )
        let first = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        #expect(first["model"] as? String == AIModelDefaults.promptCacheDiagnosticFixture)
        #expect(first["session_id"] as? String == "cache-diagnostic-fixed-run")
        #expect((first["session_id"] as? String) == (second["session_id"] as? String))

        let firstMessages = try #require(first["messages"] as? [[String: Any]])
        let secondMessages = try #require(second["messages"] as? [[String: Any]])
        #expect(firstMessages.count == 2)
        #expect(secondMessages.count == 4)
        let firstSystem = try #require(firstMessages[0]["content"] as? [[String: Any]])
        let secondSystem = try #require(secondMessages[0]["content"] as? [[String: Any]])
        let paper = try #require(firstSystem[0]["text"] as? String)
        #expect(paper.contains("PAPER-TEXT-START"))
        #expect(paper.contains("PAPER-TEXT-END"))
        #expect(paper.contains("Diagnostic run fixed-run"))
        #expect(secondSystem[0]["text"] as? String == paper)
        let marker = try #require(firstSystem[0]["cache_control"] as? [String: Any])
        #expect(marker["type"] as? String == "ephemeral")
        #expect(marker["ttl"] as? String == "1h")
    }

    @Test("In-app live diagnostic requires a substantive provider-reported cache hit")
    func promptCacheDiagnosticValidatesObservedUsage() throws {
        let first = Data(#"{"choices":[{"message":{"content":"Acknowledged."}}],"usage":{"prompt_tokens":10000,"prompt_tokens_details":{"cached_tokens":0,"cache_write_tokens":9500},"cost":0.012}}"#.utf8)
        let second = Data(#"{"choices":[{"message":{"content":"Retrieval practice."}}],"usage":{"prompt_tokens":10100,"prompt_tokens_details":{"cached_tokens":9000,"cache_write_tokens":0},"cost":0.003}}"#.utf8)

        let result = try PromptCacheDiagnostic.validate(firstData: first, secondData: second)
        #expect(result.firstPromptTokens == 10_000)
        #expect(result.cacheWriteTokens == 9_500)
        #expect(result.cachedReadTokens == 9_000)
        #expect(result.hitRate == 0.9)
        #expect(abs(result.totalProviderCostUSD - 0.015) < 0.000_001)

        let miss = Data(#"{"usage":{"prompt_tokens":10100,"prompt_tokens_details":{"cached_tokens":1000,"cache_write_tokens":0},"cost":0.01}}"#.utf8)
        do {
            _ = try PromptCacheDiagnostic.validate(firstData: first, secondData: miss)
            Issue.record("A 10% cache reuse rate must fail the diagnostic.")
        } catch let error as PromptCacheDiagnostic.DiagnosticError {
            #expect(error == .cacheHitMissing(cached: 1_000, firstPrompt: 10_000))
        }
    }

    @Test("OpenAI-style cache marking annotates the system prompt and trailing user message")
    func openAIStyleCacheMarkingSystemAndLastUser() {
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints([
            ["role": "system", "content": "instructions + source text"],
            ["role": "user", "content": "first question"],
            ["role": "assistant", "content": "answer"],
            ["role": "user", "content": "follow-up"],
        ])

        let systemBlocks = marked[0]["content"] as? [[String: Any]]
        #expect(systemBlocks?.count == 1)
        #expect(systemBlocks?.first?["text"] as? String == "instructions + source text")
        #expect((systemBlocks?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        // Intermediate turns stay untouched string content.
        #expect(marked[1]["content"] as? String == "first question")
        #expect(marked[2]["content"] as? String == "answer")

        let lastBlocks = marked[3]["content"] as? [[String: Any]]
        #expect((lastBlocks?.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test("Tool rounds carry the trailing breakpoint on the last tool result")
    func openAIStyleCacheMarkingTrailingToolMessage() {
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints([
            ["role": "system", "content": "instructions"],
            ["role": "user", "content": "question"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "t1"]] as [[String: Any]]],
            ["role": "tool", "tool_call_id": "t1", "content": "result one"],
            ["role": "tool", "tool_call_id": "t2", "content": "result two"],
        ])

        // Only the LAST tool result gets the marker — one breakpoint caches
        // the whole conversation prefix built so far.
        #expect(marked[3]["content"] as? String == "result one")
        let lastBlocks = marked[4]["content"] as? [[String: Any]]
        #expect(lastBlocks?.count == 1)
        #expect(lastBlocks?.first?["text"] as? String == "result two")
        #expect((lastBlocks?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test("Every catalog model has a deliberate cache policy")
    func everyCatalogModelHasACachePolicy() {
        for entry in AIModelCatalog.allEntries {
            let slug = OpenRouterModelID.slug(provider: entry.provider, model: entry.modelID)
            let policy = AIService.openRouterCachePolicy(for: slug)

            // Anthropic and Gemini must resolve through the prefix rules, not
            // fall through to `.implicit` — that fallthrough is what silently
            // disabled caching for a whole family before.
            if slug.hasPrefix("anthropic/") {
                #expect(policy == .explicitBreakpoints(ttl: "1h"), "\(slug) lost its 1h TTL")
            }
            if slug.hasPrefix("google/gemini") {
                #expect(policy == .explicitBreakpoints(ttl: nil), "\(slug) should not send a ttl")
            }
            // GPT-5.6 and later list `supports_implicit_caching: false` and bill a
            // write at 1.25x; left implicit they pay the premium and keep the
            // entry about a minute (measured 2026-10-15: 4% read after a pause).
            if slug.hasPrefix("openai/"), AIModelDefaults.openAIBillsCacheWrites(slug) {
                #expect(policy == .explicitBreakpoints(ttl: nil), "\(slug) must use explicit breakpoints")
            }
            // A model may only claim implicit caching if it isn't one we have
            // already measured as non-caching.
            if policy == .implicit {
                #expect(slug != "meta/muse-spark-1.2", "meta/muse-spark-1.2 does not cache implicitly")
                #expect(slug != "meta/muse-spark-1.1", "meta/muse-spark-1.1 does not cache implicitly")
            }
        }
    }

    @Test("OpenRouter's catalog decides every model's effort levels")
    func openRouterCatalogReasoningEfforts() {
        // The catalog's rows as OpenRouter published them on 2026-09-27.
        let payload = Data(#"""
        {
          "data": [
            { "slug": "z-ai/glm-5.3-flash",
              "endpoint": { "model_variant_slug": "z-ai/glm-5.3-flash" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["low", "high", "max"], "default_reasoning_effort": "max" } },
            { "slug": "meta/muse-spark-1.2",
              "endpoint": { "model_variant_slug": "meta/muse-spark-1.2" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["minimal", "low", "medium", "high", "xhigh"], "default_reasoning_effort": "medium" } },
            { "slug": "openai/gpt-5.6-sol",
              "endpoint": { "model_variant_slug": "openai/gpt-5.6-sol" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["high", "low", "medium", "none", "xhigh", "max"], "default_reasoning_effort": "medium" } },
            { "slug": "anthropic/claude-opus-5.5",
              "endpoint": { "model_variant_slug": "anthropic/claude-opus-5.5" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["low", "medium", "high", "xhigh", "max"], "default_reasoning_effort": "high" } },
            { "slug": "google/gemini-3.8-flash",
              "endpoint": { "model_variant_slug": "google/gemini-3.8-flash" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["medium", "low", "high"], "default_reasoning_effort": "medium" } },
            { "slug": "google/gemini-3.1-flash-lite",
              "endpoint": { "model_variant_slug": "google/gemini-3.1-flash-lite" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["medium", "minimal", "low", "high"], "default_reasoning_effort": "minimal" } },
            { "slug": "qwen/qwen3.8-27b",
              "endpoint": { "model_variant_slug": "qwen/qwen3.8-27b:free" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["low", "medium", "high"], "default_reasoning_effort": "low" } },
            { "slug": "openai/gpt-5-pro",
              "endpoint": { "model_variant_slug": "openai/gpt-5-pro" },
              "reasoning_config": { "supports_reasoning_effort": true,
                "supported_reasoning_efforts": ["high"], "default_reasoning_effort": null } },
            { "slug": "qwen/qwen3-32b",
              "endpoint": { "model_variant_slug": "qwen/qwen3-32b" },
              "reasoning_config": { "supports_reasoning_effort": null } }
          ]
        }
        """#.utf8)
        let table = AIService.openRouterReasoningEffortTable(rows: AIService.openRouterCatalogRows(from: payload))
        #expect(table["z-ai/glm-5.3-flash"] == OpenRouterReasoningEfforts(efforts: ["low", "high", "max"], defaultEffort: "max"))
        #expect(table["qwen/qwen3.8-27b:free"] != nil)
        #expect(table["qwen/qwen3-32b"] == nil)

        AIModelCatalog.$openRouterReasoningEffortsOverride.withValue(table) {
            #expect(AIModelCatalog.hasReadOpenRouterReasoningEfforts)
            // GLM 5.3 Flash takes low/high/max and runs at max when none is sent.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openRouter, model: "z-ai/glm-5.3-flash")
                == [.low, .high, .max])
            #expect(AIRequestOptionSupport.displayDefaultEffort(provider: .openRouter, model: "z-ai/glm-5.3-flash") == .max)
            // Every level OpenRouter lists is offered, minimal and none included.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .meta, model: "muse-spark-1.2")
                == [.minimal, .low, .medium, .high, .extraHigh])
            #expect(AIRequestOptionSupport.displayDefaultEffort(provider: .meta, model: "muse-spark-1.2") == .medium)
            #expect(AIRequestOptionSupport.displayDefaultEffort(provider: .gemini, model: "gemini-3.1-flash-lite") == .minimal)
            // Claude and GPT follow the catalog too, past their labs' tables:
            // GPT-5.6 Sol (the "gpt-5.6" alias) takes none through max.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openai, model: "gpt-5.6")
                == [.noReasoning, .low, .medium, .high, .extraHigh, .max])
            #expect(AIRequestOptionSupport.displayDefaultEffort(provider: .openai, model: "gpt-5.6") == .medium)
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .anthropic, model: "claude-opus-5-5")
                == [.low, .medium, .high, .extraHigh, .max])
            // A model the catalog lists no control for has none, curated or not.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .anthropic, model: "claude-haiku-4-5").isEmpty)
            // The catalog's order is not the app's: levels come back fastest
            // first, and a native Gemini id finds its OpenRouter slug.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .gemini, model: "gemini-3.8-flash")
                == [.low, .medium, .high])
            // A `:free` variant reads its own row.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openRouter, model: "qwen/qwen3.8-27b:free")
                == [.low, .medium, .high])
            // One level is no choice; no effort control is none.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openai, model: "gpt-5-pro").isEmpty)
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openRouter, model: "qwen/qwen3-32b").isEmpty)
        }
        // An empty catalog read never replaces the table already held.
        #expect(AIModelCatalog.cacheOpenRouterReasoningEfforts([:]) == false)
    }

    @Test("Stable prefix is byte-identical across turns of one conversation")
    @MainActor
    func stablePrefixSurvivesRetitleAndNotebookNotesEdit() {
        let paper = String(repeating: "Attached paper body. ", count: 2_000)
        let question = "Why might mitochondrial transplantation work mechanistically?"
        let instructions = "Meetings are Thursday at 10 am PT and review that week's Acme Nexus session."
        let notebookMaterials = "The brief requires a causal model and a reproducible validation analysis."
        let (first, second) = ReviewSessionManager.stablePrefixAcrossTurnsForTesting(
            sourceContext: paper,
            firstTopic: "Explain GDF15",
            retitledTopic: "GDF15 and Metabolic Signaling",
            firstNotebookNotesMarkdown: "## Notes\n- initial point",
            editedNotebookNotesMarkdown: "## Notes\n- initial point\n- added by replace_synthesis",
            notebookInstructions: instructions,
            researchQuestions: [question],
            notebookMaterialsMarkdown: notebookMaterials
        )

        // The invariant the whole cache depends on: an auto-retitle, a Notebook-notes
        // edit, and a turn's tool results must not perturb one byte of the
        // cached prefix. Compare bytes, not lengths — a same-length swap
        // (e.g. two equal-length titles) still misses.
        #expect(first.stable == second.stable)
        #expect(first.stable.contains(paper.trimmingCharacters(in: .whitespacesAndNewlines)))

        // ...and the mutable fields must actually still reach the model,
        // just from the uncached tail.
        #expect(first.volatile.contains("Explain GDF15"))
        #expect(second.volatile.contains("GDF15 and Metabolic Signaling"))
        #expect(second.volatile.contains("added by replace_synthesis"))
        #expect(first.volatile != second.volatile)

        // Guard against the fix regressing into "cache everything by moving
        // nothing" — the source text must stay in the cached half.
        #expect(!first.volatile.contains(paper))

        // The Notebook's defining questions belong on the cached side: no tool
        // rewrites them mid-session, so they must not pay the volatile tax the
        // notes rightly pay.
        #expect(first.stable.contains(question))
        #expect(!first.volatile.contains(question))
        #expect(first.stable.contains(instructions))
        #expect(first.stable.contains("even when the Notebook has no approved sources"))
        #expect(first.stable.contains("empty source pool means only that no source-content evidence is available"))
        #expect(!first.volatile.contains(instructions))
        #expect(first.stable.contains(notebookMaterials))
        #expect(!first.volatile.contains(notebookMaterials))
    }

    @Test("Trailing assistant message stays unmarked")
    func openAIStyleCacheMarkingSkipsTrailingAssistant() {
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints([
            ["role": "system", "content": "instructions"],
            ["role": "user", "content": "question"],
            ["role": "assistant", "content": "partial answer"],
        ])
        #expect(marked[2]["content"] as? String == "partial answer")
    }

    @Test("Pre-split system content keeps the breakpoint on the stable head")
    func openAIStyleCacheMarkingPreSplitSystem() {
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints([
            ["role": "system", "content": [
                ["type": "text", "text": "stable instructions + source"],
                ["type": "text", "text": "volatile digest"],
            ] as [[String: Any]]],
            ["role": "user", "content": "question"],
        ])

        let blocks = marked[0]["content"] as? [[String: Any]]
        // Breakpoint on the stable head, not the volatile tail — otherwise
        // digest churn would invalidate the cached source text.
        #expect((blocks?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(blocks?.last?["cache_control"] == nil)
    }

    @Test("History digest and continuity instruction land in the volatile system tail")
    @MainActor
    func historyDigestStaysOutOfStableSystem() {
        let messages = (0..<26).map { index in
            (role: index.isMultiple(of: 2) ? "user" : "assistant", content: "TURN-\(index)")
        }
        let parts = ReviewSessionManager.historyDigestPayloadPartsForTesting(
            messages: messages,
            digest: "DIGEST-MARKER",
            coveredMessageCount: 4,
            systemPrompt: "STABLE-SYSTEM"
        )

        // The stable head (instructions + source text) must stay byte-identical
        // across turns so the provider cache keeps hitting.
        #expect(parts.stable == "STABLE-SYSTEM")
        #expect(parts.volatile.contains("DIGEST-MARKER"))
        #expect(parts.volatile.contains("Earlier transcript compact:"))
    }

    @Test("Tool-message breakpoints ride inside a content block, never top level")
    func openAIStyleCacheMarkingToolTailUsesContentPart() {
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints([
            ["role": "system", "content": "instructions"],
            ["role": "user", "content": "question"],
            ["role": "tool", "tool_call_id": "c1", "content": "tool output"],
        ])

        #expect((marked[0]["content"] as? [[String: Any]]) != nil)

        // OpenRouter honours cache_control on a tool message only inside a
        // content part — a top-level marker is ignored and has been reported to
        // hang the request. Keep tool_call_id intact so the result still pairs.
        #expect(marked[2]["cache_control"] == nil)
        #expect(marked[2]["tool_call_id"] as? String == "c1")
        let blocks = marked[2]["content"] as? [[String: Any]]
        #expect(blocks?.count == 1)
        #expect(blocks?.first?["text"] as? String == "tool output")
        #expect((blocks?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test("An empty trailing tool message is skipped rather than marked top level")
    func openAIStyleCacheMarkingSkipsEmptyToolTail() {
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints([
            ["role": "system", "content": "instructions"],
            ["role": "tool", "tool_call_id": "c1", "content": "   "],
        ])

        // No content part can carry the marker, and a top-level one would be
        // ignored (or worse) — leave the message untouched.
        #expect(marked[1]["cache_control"] == nil)
        #expect(marked[1]["content"] as? String == "   ")
    }

    @Test("Claude via OpenRouter gets the 1h system TTL; the trailing breakpoint keeps 5m")
    func openAIStyleCacheMarkingSystemTTL() {
        #expect(AIService.openRouterModelSupportsCacheTTL("anthropic/claude-sonnet-4-6"))
        // OpenRouter documents ttl for Anthropic only; Qwen caching is a flat
        // 5 minutes and an unknown ttl field there is undocumented.
        #expect(!AIService.openRouterModelSupportsCacheTTL("qwen/qwen3-max"))

        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints(
            [
                ["role": "system", "content": "instructions + source text"],
                ["role": "tool", "tool_call_id": "c1", "content": "tool output"],
            ],
            systemTTL: "1h"
        )

        let systemMarker = (marked[0]["content"] as? [[String: Any]])?
            .first?["cache_control"] as? [String: Any]
        #expect(systemMarker?["ttl"] as? String == "1h")

        // Anthropic requires longer-TTL breakpoints to precede shorter ones,
        // so the trailing message must stay at the default 5 minutes.
        let lastMarker = (marked[1]["content"] as? [[String: Any]])?
            .last?["cache_control"] as? [String: Any]
        #expect(lastMarker?["type"] as? String == "ephemeral")
        #expect(lastMarker?["ttl"] == nil)
    }

    @Test("Qwen via OpenRouter gets no ttl field at all")
    func openAIStyleCacheMarkingOmitsTTLWhenUnsupported() {
        let marked = AIService.openAIStyleMessagesMarkingCacheBreakpoints([
            ["role": "system", "content": "instructions"],
            ["role": "user", "content": "question"],
        ])

        let systemMarker = (marked[0]["content"] as? [[String: Any]])?
            .first?["cache_control"] as? [String: Any]
        #expect(systemMarker?["type"] as? String == "ephemeral")
        #expect(systemMarker?["ttl"] == nil)
    }
}
