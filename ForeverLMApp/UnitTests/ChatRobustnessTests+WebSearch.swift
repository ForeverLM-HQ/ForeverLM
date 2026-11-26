// Chat robustness tests: web search, web citations and tool-call parsing.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

extension ChatRobustnessTests {
    // MARK: - Web search

    @Test("Web search attaches OpenRouter's web plugin only when enabled")
    @MainActor
    func webSearchPluginAttachesWhenEnabled() async throws {
        let service = AIService()
        let turns: [AIChatTurn] = [.user("What changed in the field this month?")]

        let without = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter, system: "S", volatileSystem: "", turns: turns,
            tools: [], maxTokens: 200, model: "anthropic/claude-sonnet-5", effort: nil
        )
        #expect(without["plugins"] == nil)

        let with = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter, system: "S", volatileSystem: "", turns: turns,
            tools: [], maxTokens: 200, model: "anthropic/claude-sonnet-5", effort: nil,
            webSearch: true
        )
        let plugins = try #require(with["plugins"] as? [[String: Any]])
        #expect(plugins.count == 1)
        #expect(plugins.first?["id"] as? String == "web")
        // The plugin must ride the plain slug: the managed proxy prices the
        // request by looking `model` up in OpenRouter's directory, and the
        // `:online` suffixed alias is not in it.
        #expect((with["model"] as? String)?.contains(":online") == false)
        // Deterministic serialization must accept the payload with the plugin.
        _ = try AIService.stableJSONBody(with)
    }

    @Test("Exa-engine models skip the web plugin on tool continuation rounds")
    @MainActor
    func webSearchSkipsExaContinuationRounds() async throws {
        let service = AIService()
        let continuationTurns: [AIChatTurn] = [
            .user("Compare this against the wider literature"),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "call_1", name: "list_sources", argumentsJSON: "{}")
            ]),
            .toolResults([
                AIToolResultPayload(callID: "call_1", toolName: "list_sources", text: "3 sources", isError: false)
            ]),
        ]

        // No native web search for this slug: the Exa engine would search once
        // per request, so continuation rounds must not carry the plugin.
        let exa = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter, system: "S", volatileSystem: "", turns: continuationTurns,
            tools: [], maxTokens: 200, model: "deepseek/deepseek-v3.2", effort: nil,
            webSearch: true
        )
        #expect(exa["plugins"] == nil)

        // Native engines bill only performed searches, so they keep the tool
        // available on every round.
        let native = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter, system: "S", volatileSystem: "", turns: continuationTurns,
            tools: [], maxTokens: 200, model: "anthropic/claude-sonnet-5", effort: nil,
            webSearch: true
        )
        #expect(native["plugins"] != nil)

        let explicitEscalationTurns: [AIChatTurn] = [
            .user("Find current literature only if my library has no match"),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(
                    id: "call_web",
                    name: "request_web_search",
                    argumentsJSON: #"{"query":"current literature"}"#
                )
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "call_web",
                    toolName: "request_web_search",
                    text: "Live web search is enabled for the next assistant step.",
                    isError: false
                )
            ]),
        ]
        let escalatedExa = await service.makeOpenAIStyleToolPayload(
            provider: .openRouter, system: "S", volatileSystem: "", turns: explicitEscalationTurns,
            tools: [], maxTokens: 200, model: "deepseek/deepseek-v3.2", effort: nil,
            webSearch: true
        )
        #expect(escalatedExa["plugins"] != nil)

        #expect(AIService.openRouterSlugHasNativeWebSearch("anthropic/claude-sonnet-5"))
        #expect(AIService.openRouterSlugHasNativeWebSearch("openai/gpt-5.2"))
        #expect(!AIService.openRouterSlugHasNativeWebSearch("deepseek/deepseek-v3.2"))
        #expect(!AIService.openRouterSlugHasNativeWebSearch("qwen/qwen3-max"))
    }

    @Test("url_citation annotations accumulate deduplicated across stream shapes")
    func webCitationAnnotationsAccumulate() {
        var accumulator = AIToolCallStreamAccumulator()
        // Documented nested shape on a delta.
        accumulator.consume([
            "choices": [[
                "delta": [
                    "content": "Recent work",
                    "annotations": [[
                        "type": "url_citation",
                        "url_citation": ["url": "https://example.org/a", "title": "Paper A"],
                    ]],
                ],
            ]],
        ])
        // Same URL again on the final message plus a flattened variant.
        accumulator.consume([
            "choices": [[
                "message": [
                    "annotations": [
                        ["type": "url_citation", "url_citation": ["url": "https://example.org/a", "title": "Paper A"]],
                        ["type": "url_citation", "url": "https://example.org/b"],
                    ],
                ],
            ]],
        ])

        #expect(accumulator.webCitations == [
            AIWebCitation(url: "https://example.org/a", title: "Paper A"),
            AIWebCitation(url: "https://example.org/b", title: ""),
        ])
        // Annotations are not tool calls and must not trip the tool loop.
        #expect(accumulator.toolCalls.isEmpty)
        #expect(!accumulator.sawToolUseStop)
    }

    @Test("Web sources footer lists every cited page, including ones linked inline")
    @MainActor
    func webSourcesFooterListsEveryCitation() {
        let citations = [
            AIWebCitation(url: "https://example.org/inline", title: "Already linked"),
            AIWebCitation(url: "https://example.org/fresh", title: "New [2026] result"),
            AIWebCitation(url: "https://untitled.example.org/page", title: ""),
        ]
        let reply = "As covered in [the inline citation](https://example.org/inline), the field moved."

        let footered = ReviewSessionManager.appendingWebSourcesFooter(to: reply, citations: citations)
        #expect(footered.contains("**Web sources**"))
        // The list is where a page gets kept from, so an inline link does not
        // remove it from the list.
        #expect(footered.contains("1. [Already linked](https://example.org/inline)"))
        #expect(footered.contains("2. [New (2026) result](https://example.org/fresh)"))
        #expect(footered.contains("3. [untitled.example.org](https://untitled.example.org/page)"))

        // No citations: the reply comes back untouched.
        #expect(ReviewSessionManager.appendingWebSourcesFooter(to: reply, citations: []) == reply)

        let merged = ReviewSessionManager.mergingWebCitations(
            [citations[0]],
            adding: [citations[0], citations[1]]
        )
        #expect(merged == [citations[0], citations[1]])
    }

    @Test("Web links to pages already in the library become library citations; the rest stay web links")
    func webLinksToLibraryPagesBecomeSourceCitations() {
        let reply = """
        He measures the variable directly ([consciousrepository.com](https://www.consciousrepository.com/p/a-boring-mri)). \
        Replication is not validation ([consciousrepository.com](https://www.consciousrepository.com/p/replication)).

        ![figure](https://www.consciousrepository.com/p/a-boring-mri)
        """
        let library = ["https://www.consciousrepository.com/p/a-boring-mri": "src_mri"]
        let linked = ReviewSessionManager.linkingLibrarySources(in: reply) { library[$0] }
        #expect(linked.contains("([consciousrepository.com](foreverlm://source/src_mri))"))
        #expect(linked.contains("([consciousrepository.com](https://www.consciousrepository.com/p/replication))"))
        // An image reference is a picture, not a citation.
        #expect(linked.contains("![figure](https://www.consciousrepository.com/p/a-boring-mri)"))
        #expect(ReviewSessionManager.webLinkTargets(in: reply)
            == ["https://www.consciousrepository.com/p/a-boring-mri", "https://www.consciousrepository.com/p/replication"])
        // Nothing known: the text comes back untouched.
        #expect(ReviewSessionManager.linkingLibrarySources(in: reply) { _ in nil } == reply)
    }

    @Test("A shown reply cites a kept paper by the paper, not its web page; the Web sources footer stays web")
    func shownReplyLinksKeptPaperButNotFooter() {
        let reply = """
        Scores were compared with fibroblast respiration ([nature.com](https://www.nature.com/articles/s41467-025-0001-x)). \
        Another lab disagrees ([example.org](https://example.org/rebuttal)).

        **Web sources**
        1. [Mitotyping](https://www.nature.com/articles/s41467-025-0001-x)
        2. [Rebuttal](https://example.org/rebuttal)
        """
        let library = ["https://www.nature.com/articles/s41467-025-0001-x": "src_monzel"]
        let shown = ReviewSessionManager.linkingLibraryHeldWebPages(in: reply) { library[$0] }
        #expect(shown.contains("([nature.com](foreverlm://source/src_monzel))"))
        #expect(shown.contains("([example.org](https://example.org/rebuttal))"))
        #expect(shown.contains("1. [Mitotyping](https://www.nature.com/articles/s41467-025-0001-x)"))
        #expect(ReviewSessionManager.splitWebSourcesFooter(shown).citations.count == 2)
        #expect(ReviewSessionManager.linkingLibraryHeldWebPages(in: reply) { _ in nil } == reply)
    }

    @Test("A 【Title】 citation becomes the source's link; one that names nothing keeps its words")
    func bracketMarkerCitationsBecomeSourceLinks() {
        var index = ChatSourceTitleIndex()
        index.note(id: "src_finbow", title: "Mitochondrial dynamics and in vivo sensing with Anthony Finbow")
        index.harvest(toolResult: """
        {"results": [{"source_id": "src_json", "title": "Redox Signalling [Review]"}]}
        """)
        index.harvest(toolResult: "- [paper] Cristae remodelling (id: src_list, 4,120 words)")
        index.harvest(toolResult: "Best match: [Quiet Hearts](foreverlm://source/src%20link)")
        index.note(id: "src_a", title: "Twin")
        index.note(id: "src_b", title: "Twin")

        let reply = "Fission is tuned by the cell【Mitochondrial dynamics and in vivo sensing with Anthony Finbow】. "
            + "Also 【  cristae   REMODELLING 】, 【Redox Signalling [Review]】 and 【Quiet Hearts】; "
            + "【Twin】 and 【Unknown Talk】 stay plain, as does [【Cristae remodelling】](foreverlm://source/src_list)."
        let repaired = index.repairing(reply)

        #expect(repaired.contains("cell[Mitochondrial dynamics and in vivo sensing with Anthony Finbow](foreverlm://source/src_finbow)."))
        #expect(repaired.contains("[Cristae remodelling](foreverlm://source/src_list),"))
        #expect(repaired.contains("[Redox Signalling \\[Review\\]](foreverlm://source/src_json)"))
        #expect(repaired.contains("[Quiet Hearts](foreverlm://source/src%20link);"))
        #expect(repaired.contains(" Twin and Unknown Talk stay plain"))
        // Inside a link's own brackets the marker only loses its brackets.
        #expect(repaired.contains("[Cristae remodelling](foreverlm://source/src_list)."))
        #expect(!repaired.contains("\u{3010}") && !repaired.contains("\u{3011}"))
        // The repaired citations are read as citations by the ledger.
        #expect(ChatCitationLedger.citations(in: repaired).map(\.token)
            == ["src_finbow", "src_list", "src_json", "src link", "src_list"])
        // A reply with no marker is returned untouched.
        #expect(index.repairing("Nothing to fix [here](foreverlm://source/src_a).") == "Nothing to fix [here](foreverlm://source/src_a).")
    }

    @Test("A source id printed as text becomes the source's citation; ids in links and tags stay")
    func printedSourceIDsBecomeCitations() {
        let id = "src_fa3cbe10a8f3f227d0cd27287b4ae262ad27332d1023ec9d45421bd040f05795"
        let other = "src_00bbb3f26f409809ce6704ec2d2bd9c7ac56695d7867e50690d18383a10d89c4"
        let titles = [id: "A Voltmeter for Organelles"]
        let link = "[A Voltmeter for Organelles](foreverlm://source/\(id))"

        let reply = "Measured directly\(id). Dyes reach mitochondria (\(id), \(other)). "
            + "GEVIs are pH-sensitive [\(id)], `\(id)`, as in [the paper](\(id)) and (src_fa3cbe10…)."
        let linked = ChatSourceIDCitations.linking(reply, titleByID: titles)

        #expect(linked.contains("Measured directly\(link)."))
        #expect(linked.contains("mitochondria\(link)[Source](foreverlm://source/\(other))."))
        #expect(linked.contains("pH-sensitive\(link),\(link), as in [the paper](foreverlm://source/\(id)) and\(link.replacingOccurrences(of: id, with: "src_fa3cbe10"))."))
        #expect(ChatCitationLedger.citations(in: linked).count == 7)
        // Without a title the link still cites; the renderer draws the card.
        #expect(ChatSourceIDCitations.linking("Shown\(id).") == "Shown[Source](foreverlm://source/\(id)).")
        // Ids where ids belong, and one still streaming in, are left alone.
        for untouched in [
            "[Paper](foreverlm://source/\(id)?t=12) and [\(id)](foreverlm://source/\(id))",
            "<flm_source_turn id=\"\(id)\"/>",
            "Streaming src_fa3cbe10a8f3f2",
        ] {
            #expect(ChatSourceIDCitations.linking(untouched, titleByID: titles) == untouched)
        }
    }

    @Test("Web sources footer is defensively capped")
    @MainActor
    func webSourcesFooterHasMaximum() {
        let citations = (1...25).map {
            AIWebCitation(url: "https://example.org/\($0)", title: "Source \($0)")
        }
        let footered = ReviewSessionManager.appendingWebSourcesFooter(
            to: "Answer without inline links.",
            citations: citations
        )

        #expect(footered.contains("20. [Source 20]"))
        #expect(!footered.contains("Source 21"))
    }

    @Test("Web sources footer round-trips into native rows and leaves prose alone")
    @MainActor
    func webSourcesFooterSplitsBackIntoCitations() {
        let citations = [
            AIWebCitation(url: "https://example.org/a?x=1", title: "First (2026) page"),
            AIWebCitation(url: "https://example.org/b", title: "example.org"),
        ]
        let body = "The answer.\n\nWith two paragraphs."
        let footered = ReviewSessionManager.appendingWebSourcesFooter(to: body, citations: citations)

        let split = ReviewSessionManager.splitWebSourcesFooter(footered)
        #expect(split.body == body)
        #expect(split.citations == citations)

        // No footer: the whole reply is body.
        let plain = ReviewSessionManager.splitWebSourcesFooter(body)
        #expect(plain.body == body)
        #expect(plain.citations.isEmpty)

        // The heading in prose, followed by something that is not a link list,
        // is not a footer.
        let prose = "Compare the **Web sources** section.\n\n**Web sources**\nare listed elsewhere."
        let unsplit = ReviewSessionManager.splitWebSourcesFooter(prose)
        #expect(unsplit.body == prose)
        #expect(unsplit.citations.isEmpty)

        // A non-web link in the list disqualifies it rather than producing an
        // Add button for something the library cannot import.
        let bad = body + "\n\n**Web sources**\n1. [Local](file:///etc/passwd)"
        #expect(ReviewSessionManager.splitWebSourcesFooter(bad).citations.isEmpty)
    }

    @Test("One cited page is one row, whatever URL form it arrived under")
    @MainActor
    func webSourcesListOneRowPerPage() {
        let paper = "Tau-induced mitochondrial reverse electron transport drives neurodegeneration"
        // Verbatim shapes from a reply that listed this paper four times: the
        // provider's search cited PMC, ScienceDirect and PubMed, and a page
        // read came back under NCBI's older shared-domain path.
        let citations = [
            AIWebCitation(url: "https://pmc.ncbi.nlm.nih.gov/articles/PMC12119548/", title: "\(paper) - PMC"),
            AIWebCitation(
                url: "https://www.sciencedirect.com/science/article/abs/pii/S0891584925003983?via%3Dihub",
                title: "\(paper) - ScienceDirect"
            ),
            AIWebCitation(url: "https://pubmed.ncbi.nlm.nih.gov/40467740/", title: "\(paper) - PubMed"),
            AIWebCitation(url: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12119548/#abstract1", title: "\(paper) - PMC"),
        ]

        let deduplicated = AIWebCitation.deduplicated(citations)
        // The first URL survives, since that is the form the reply's prose links.
        #expect(deduplicated == [citations[0]])

        // Two pages that merely share a host stay two rows.
        let distinct = AIWebCitation.deduplicated([
            AIWebCitation(url: "https://pmc.ncbi.nlm.nih.gov/articles/PMC12119548/", title: "\(paper) - PMC"),
            AIWebCitation(url: "https://pmc.ncbi.nlm.nih.gov/articles/PMC9999999/", title: "A different paper entirely - PMC"),
        ])
        #expect(distinct.count == 2)
    }

    @Test("A DOI in the URL identifies the page over the path it sits in")
    @MainActor
    func webCitationDOIIdentity() {
        #expect(AIWebCitation.doi(in: "https://doi.org/10.1002/alz.70123") == "10.1002/alz.70123")
        #expect(AIWebCitation.doi(in: "https://onlinelibrary.wiley.com/doi/pdf/10.1002/alz.70123") == "10.1002/alz.70123")
        // A prefix with no suffix is not a DOI, and neither is a date.
        #expect(AIWebCitation.doi(in: "https://example.org/10.1002/") == nil)
        #expect(AIWebCitation.doi(in: "https://example.org/2026/10.5-things") == nil)

        let merged = AIWebCitation.deduplicated([
            AIWebCitation(url: "https://onlinelibrary.wiley.com/doi/10.1002/alz.70123", title: "Landing"),
            AIWebCitation(url: "https://onlinelibrary.wiley.com/doi/pdf/10.1002/alz.70123", title: "PDF"),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].title == "Landing")

        // PubMed and PMC accessions name different NCBI pages and cannot be
        // mapped onto each other, so nothing but a matching accession collapses.
        #expect(AIWebCitation.ncbiAccession(in: "https://pubmed.ncbi.nlm.nih.gov/40467740/") == "pmid:40467740")
        #expect(AIWebCitation.ncbiAccession(in: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12119548/") == "pmc:pmc12119548")
        #expect(AIWebCitation.ncbiAccession(in: "https://example.org/pmc12119548") == nil)
    }

    @Test("A title only stands in for a work when it names one")
    @MainActor
    func webCitationTitleIdentityIsGuarded() {
        // Short and generic titles decide nothing: these are two pages.
        let generic = AIWebCitation.deduplicated([
            AIWebCitation(url: "https://a.example.org/paper", title: "PDF"),
            AIWebCitation(url: "https://b.example.org/paper", title: "PDF"),
        ])
        #expect(generic.count == 2)

        // A numbered suffix names a different document, not the publisher, so
        // it is never stripped.
        let paginated = AIWebCitation.deduplicated([
            AIWebCitation(url: "https://a.example.org/1", title: "The long form investigation into the collapse - Part 1"),
            AIWebCitation(url: "https://a.example.org/2", title: "The long form investigation into the collapse - Part 2"),
        ])
        #expect(paginated.count == 2)

        // An untitled row adopts the title a later duplicate carried.
        let adopted = AIWebCitation.deduplicated([
            AIWebCitation(url: "https://example.org/page", title: ""),
            AIWebCitation(url: "https://example.org/page/", title: "The page's real title"),
        ])
        #expect(adopted == [AIWebCitation(url: "https://example.org/page", title: "The page's real title")])
    }

    @Test("A reply saved with duplicate sources renders one row per page")
    @MainActor
    func webSourcesFooterFoldsDuplicatesOnRead() {
        let paper = "Tau-induced mitochondrial reverse electron transport drives neurodegeneration"
        let saved = """
        The answer.

        **Web sources**
        1. [\(paper) - PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC12119548/)
        2. [\(paper) - PubMed](https://pubmed.ncbi.nlm.nih.gov/40467740/)
        """

        let split = ReviewSessionManager.splitWebSourcesFooter(saved)
        #expect(split.body == "The answer.")
        #expect(split.citations.count == 1)
        #expect(split.citations[0].url == "https://pmc.ncbi.nlm.nih.gov/articles/PMC12119548/")
    }

    @Test("A tool call with a stray closing brace still runs")
    @MainActor
    func toolCallWithTrailingBraceStillParses() {
        // Verbatim from a chat that stalled: the model wrote one brace too many,
        // the call was rejected, and the learner was left holding the lead-in
        // prose with the block stripped out of it.
        let response = """
        I\u{2019}ll pull the meeting notes/transcript so the questions are grounded in the session itself.<flm_tool_call>{"tool":"foreverlm_tool","name":"search_sources_semantic","arguments":{"query":"meeting notes transcript key questions","source_type":"meeting","limit":8}}}</flm_tool_call>
        """

        let call = ReviewSessionManager.appToolCallForTesting(response)

        #expect(call?.name == "search_sources_semantic")
        #expect(call?.arguments["source_type"] as? String == "meeting")
        #expect(call?.arguments["limit"] as? Int == 8)
    }

    @Test("A tool call whose closing tag never arrived still runs")
    @MainActor
    func toolCallWithoutClosingTagStillParses() {
        let response = """
        Looking that up.<flm_tool_call>{"tool":"foreverlm_tool","name":"list_notebooks","arguments":{}}
        """

        #expect(ReviewSessionManager.appToolCallForTesting(response)?.name == "list_notebooks")
    }

    @Test("Prose after the tool call object is ignored, not fatal")
    @MainActor
    func toolCallWithTrailingProseStillParses() {
        let response = """
        <flm_tool_call>{"tool":"foreverlm_tool","name":"get_source_content","arguments":{"source_id":"src_1"}} (searching now)</flm_tool_call>
        """

        let call = ReviewSessionManager.appToolCallForTesting(response)

        #expect(call?.name == "get_source_content")
        #expect(call?.arguments["source_id"] as? String == "src_1")
    }

    @Test("A tool call that is not repairable is still rejected")
    @MainActor
    func unrepairableToolCallIsRejected() {
        let truncated = """
        <flm_tool_call>{"tool":"foreverlm_tool","name":"search_sources_semantic","arguments":{"query":"half a call
        """
        let wrongTool = """
        <flm_tool_call>{"tool":"something_else","name":"search_sources_semantic","arguments":{}}</flm_tool_call>
        """

        #expect(ReviewSessionManager.appToolCallForTesting(truncated) == nil)
        #expect(ReviewSessionManager.appToolCallForTesting(wrongTool) == nil)
    }

    @Test("A promise to fetch counts as a promise whichever apostrophe it uses")
    @MainActor
    func promissoryReplyDetectedWithTypographicApostrophe() {
        #expect(ReviewSessionManager.replyPromisesUncalledToolWorkForTesting(
            "I\u{2019}ll pull the meeting notes so the questions are grounded in the session itself."
        ))
        #expect(ReviewSessionManager.replyPromisesUncalledToolWorkForTesting(
            "I'll pull the meeting notes so the questions are grounded in the session itself."
        ))
        #expect(ReviewSessionManager.replyPromisesUncalledToolWorkForTesting(
            "Let me grab the transcript."
        ))
        #expect(!ReviewSessionManager.replyPromisesUncalledToolWorkForTesting(
            "The paper\u{2019}s central claim is that the process is polyclonal, and here is why that matters."
        ))
    }

    func usageEvent(
        provider: String,
        model: String,
        input: Int,
        cached: Int? = nil,
        cacheCreation: Int? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 4_000_000_000)
    ) -> AIUsageEvent {
        AIUsageEvent(
            id: UUID().uuidString,
            provider: provider,
            model: model,
            operation: "stream_chat",
            task: "chat",
            sessionID: nil,
            createdAt: createdAt,
            inputTokens: input,
            outputTokens: 10,
            cachedInputTokens: cached,
            cacheCreationInputTokens: cacheCreation,
            reasoningTokens: nil,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: nil,
            characterCount: nil,
            durationSeconds: nil,
            providerReportedCost: nil,
            estimatedCost: nil,
            currency: nil,
            rawUsageJSON: nil
        )
    }

    @Test("Assistant text loses tool-call blocks and nothing else")
    @MainActor
    func displayableContentStripsOnlyToolCallBlocks() {
        // Prose with angle brackets takes the byte-scan fast path and comes back
        // untouched, including a fragment that only looks like the tag.
        let prose = "Compare a < b, then <em>emphasis</em> and a <flm_tool_cal fragment."
        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: prose) == prose)

        let withCall = #"Before.<flm_tool_call>{"tool":"retrieve_sources"}</flm_tool_call>After."#
        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: withCall) == "Before.After.")

        let unterminated = #"Text so far<flm_tool_call>{"tool":"#
        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: unterminated) == "Text so far")
    }

    @Test("The manager's message count follows the transcript, not its text")
    @MainActor
    func chatMessageCountFollowsTranscript() {
        let manager = ReviewSessionManager()
        #expect(manager.chatMessageCount == 0)

        manager.chatMessages.append(.init(role: .user, content: "Hello"))
        manager.chatMessages.append(.init(role: .assistant, content: ""))
        #expect(manager.chatMessageCount == 2)

        // A streamed token rewrites a message; the count a panel body depends
        // on must not move with it.
        manager.chatMessages[1].content = "Hi there"
        #expect(manager.chatMessageCount == 2)

        manager.chatMessages.removeAll()
        #expect(manager.chatMessageCount == 0)
    }

    @Test("An unmeasured row opens at an estimate that grows with its text, never at one line")
    @MainActor
    func estimatedHeightFollowsTheMarkdown() {
        let width: CGFloat = 640
        let size: CGFloat = 13
        let oneLine = ChatMarkdownHeightEstimate.estimatedHeight(markdown: "Yes.", width: width, fontSize: size)
        // One line at Codex's 1.625 leading (21.125 pt) plus the bubble's padding (15.6 pt).
        #expect(oneLine == 37)

        let paragraph = String(repeating: "Mitochondrial heteroplasmy shifts with selection. ", count: 12)
        let short = ChatMarkdownHeightEstimate.estimatedHeight(markdown: paragraph, width: width, fontSize: size)
        let long = ChatMarkdownHeightEstimate.estimatedHeight(
            markdown: [paragraph, paragraph, paragraph, paragraph].joined(separator: "\n\n"),
            width: width,
            fontSize: size
        )
        #expect(short > oneLine)
        #expect(long > short * 3)

        // Six hundred characters of body text at 13pt in a 640pt column is about
        // five lines: the estimate lands in the same neighbourhood as WebKit's
        // measurement, not at a screenful and not at a line.
        #expect(short > 80 && short < 200)

        // A narrower column wraps more, so the same text estimates taller.
        let narrow = ChatMarkdownHeightEstimate.estimatedHeight(markdown: paragraph, width: 320, fontSize: size)
        #expect(narrow > short)

        // Citations add no room of their own: a reply lists no sources under it.
        let cited = ChatMarkdownHeightEstimate.estimatedHeight(
            markdown: paragraph + " [1] and again [2].",
            width: width,
            fontSize: size
        )
        #expect(cited - short < size * 2)
    }
}
