import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

@Suite("Chat robustness")
struct ChatRobustnessTests {
    @Test("Chat repairs incomplete display math without changing its saved text")
    @MainActor
    func chatRepairsIncompleteDisplayMathForRendering() async throws {
        let malformed = [
            "A useful causal model",
            "",
            "[",
            #"\text{damage or stress}"#,
            #"\rightarrow \text{mitochondrial dysfunction}"#,
            #"\rightarrow"#,
            #"\begin{cases}"#,
            #"\text{altered ATP and redox state}"# + "\\",
            #"\text{metabolite changes}"# + "\\",
            #"\text{inflammatory signalling}"# + "\\",
            #"\text{impaired proteostasis}"# + "\\",
            "\\"
        ].joined(separator: "\n")
        let encoded = try #require(String(
            data: JSONEncoder().encode(malformed),
            encoding: .utf8
        ))
        let webView = try await Self.loadedRenderer()
        let result = try await webView.evaluateJavaScript(
            "window.foreverLMChat.normalizeLatexDisplayBlocks(\(encoded));"
        )
        let normalized = try #require(result as? String)

        #expect(normalized.contains("$$\n\\text{damage or stress}"))
        #expect(normalized.contains("\\text{altered ATP and redox state}\\\\\n"))
        #expect(normalized.hasSuffix("\\end{cases}\n$$"))
        #expect(!normalized.split(separator: "\n").contains("["))

        // Rendering repair is transient; persistence still owns the exact
        // provider response so a later renderer can reinterpret it losslessly.
        #expect(malformed.hasSuffix("\\"))
        #expect(!malformed.contains(#"\end{cases}"#))
    }

    @Test("Chat math repair ignores prose brackets and fenced examples")
    @MainActor
    func chatMathRepairIsScopedToLatex() async throws {
        let prose = "[\nordinary bracketed prose\n]"
        let fenced = ["```text", "[", #"\text{shown as source}"#, "```"]
            .joined(separator: "\n")
        let inputs = [prose, fenced]
        let webView = try await Self.loadedRenderer()

        for input in inputs {
            let encoded = try #require(String(
                data: JSONEncoder().encode(input),
                encoding: .utf8
            ))
            let result = try await webView.evaluateJavaScript(
                "window.foreverLMChat.normalizeLatexDisplayBlocks(\(encoded));"
            )
            #expect(result as? String == input)
        }
    }

    /// The bundled chat page, loaded the way a message row loads it. The
    /// renderer is one script inside the app bundle, so this is ready as soon
    /// as the page's own scripts have run; nothing is fetched.
    @MainActor
    static func loadedRenderer() async throws -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        ChatMarkdownView.loadTemplate(into: webView)
        for _ in 0..<150 {
            let ready = try await webView.evaluateJavaScript(
                "typeof window.setMarkdown === 'function' && typeof window.foreverLMChat === 'object'"
            ) as? Bool
            if ready == true { return webView }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatRendererTemplateError.neverBecameReady
    }

    enum ChatRendererTemplateError: Error {
        case neverBecameReady
    }

    @Test("AI requests have no client-side deadline")
    func aiRequestsHaveNoClientSideDeadline() async {
        let service = AIService()
        let timeout = await service.session.configuration.timeoutIntervalForRequest

        #expect(timeout == 0)
    }

    @Test("Balance refresh retries only temporary read failures")
    func balanceRefreshRetryClassification() {
        #expect(ManagedAI.isRetryableBalanceError(URLError(.networkConnectionLost)))
        #expect(ManagedAI.isRetryableBalanceError(URLError(.timedOut)))
        #expect(ManagedAI.isRetryableBalanceError(URLError(.cancelled)))
        #expect(ManagedAI.isRetryableBalanceError(
            ManagedAI.ServiceError(code: "http_503", message: "Temporarily unavailable.")
        ))
        #expect(ManagedAI.isRetryableBalanceError(
            ManagedAI.ServiceError(code: "internal_error", message: "Temporary proxy failure.")
        ))
        // The proxy's catch-all since 2026-09-23. Before, the same D1 blip
        // reached the app as Cloudflare's HTML 1101 page, decoded as http_500,
        // and was retried; the JSON answer must not lose that retry.
        #expect(ManagedAI.isRetryableBalanceError(
            ManagedAI.ServiceError(code: "internal", message: "Internal error.")
        ))

        #expect(!ManagedAI.isRetryableBalanceError(
            ManagedAI.ServiceError(code: "invalid_session", message: "Sign in again.")
        ))
        #expect(!ManagedAI.isRetryableBalanceError(
            ManagedAI.ServiceError(code: "http_400", message: "Bad request.")
        ))
        #expect(!ManagedAI.isRetryableBalanceError(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Schema mismatch"))
        ))
    }

    @Test("The balance request names the learner's day by its local midnight")
    func balanceDayStartIsLocalMidnight() throws {
        var california = Calendar(identifier: .gregorian)
        california.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 19:36 PDT: the UTC day has already turned over, the learner's has not.
        let evening = try #require(ISO8601DateFormatter().date(from: "2026-09-28T02:36:00Z"))
        #expect(ManagedAI.dayStartHeaderValue(now: evening, calendar: california) == "2026-09-27T07:00:00Z")

        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        #expect(ManagedAI.dayStartHeaderValue(now: evening, calendar: auckland) == "2026-09-27T11:00:00Z")
    }

    @Test("Provider errors never surface the payload a failing provider echoes")
    func providerErrorTextRejectsPayloadEchoes() {
        // The shape that reached a learner's chat: a Responses stream cut short
        // mid-event, so the half-received request — system prompt included —
        // became the "error message".
        let truncatedEvent = """
        {"type":"response.in_progress","response":{"id":"resp_1","status":"in_progress",\
        "instructions":"You are the ForeverLM Assistant, a general-purpose chat that runs
        """
        #expect(AIProviderErrorText.sanitized(truncatedEvent) == nil)
        #expect(AIProviderErrorText.sanitized("data: {\"type\":\"response.created\"}") == nil)
        #expect(AIProviderErrorText.sanitized("<html><body>502 Bad Gateway</body></html>") == nil)
        #expect(AIProviderErrorText.sanitized(
            "Upstream said: \"instructions\": You are the ForeverLM Assistant"
        ) == nil)

        // A real provider sentence still reaches the learner unchanged.
        #expect(AIProviderErrorText.sanitized("You exceeded your current quota.")
            == "You exceeded your current quota.")
        #expect(AIProviderErrorText.sanitized("  Rate limit reached for gpt-5.  ")
            == "Rate limit reached for gpt-5.")
        #expect(AIProviderErrorText.sanitized("   ") == nil)

        let overlong = String(repeating: "a", count: AIProviderErrorText.maximumLength + 200)
        let trimmed = AIProviderErrorText.sanitized(overlong)
        #expect(trimmed?.count == AIProviderErrorText.maximumLength + 1)
        #expect(trimmed?.hasSuffix("…") == true)

        // The error row clamps whatever reaches it, whichever subsystem raised it.
        let overlongForRow = String(
            repeating: "a",
            count: AIProviderErrorText.maximumDisplayLength + 200
        )
        #expect(AIProviderErrorText.clamped(overlongForRow).count
            == AIProviderErrorText.maximumDisplayLength + 1)
        #expect(AIProviderErrorText.clamped("Sync failed.") == "Sync failed.")
    }

    @Test("An unreadable stream event is described, never quoted")
    func unreadableStreamEventsAreDescribedNotQuoted() async {
        let service = AIService()
        let truncatedEvent =
            "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_1\","
            + "\"instructions\":\"You are the ForeverLM Assistant"

        // Nothing in the fragment is usable as an error message.
        #expect(await service.extractAPIErrorMessage(from: Data(truncatedEvent.utf8)) == nil)

        // What the learner is told instead names the event, not its contents.
        let description = await service.streamEventDescription(truncatedEvent)
        #expect(description.contains("response.in_progress"))
        #expect(description.contains("\(truncatedEvent.utf8.count) bytes"))
        #expect(!description.contains("ForeverLM Assistant"))
        #expect(!description.contains("instructions"))

        #expect(AIService.streamEventType(in: "{\"type\":\"response.completed\"}")
            == "response.completed")
        #expect(AIService.streamEventType(in: "{\"id\":\"resp_1\"}") == nil)
        // A "type" long enough to carry prose is not a type.
        let smuggled = "{\"type\":\"\(String(repeating: "x", count: 61))\"}"
        #expect(AIService.streamEventType(in: smuggled) == nil)

        // A structured provider error still comes through verbatim.
        let apiError = #"{"error":{"message":"Rate limit reached","type":"rate_limit_error"}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(apiError.utf8))
            == "Rate limit reached")

        // Even inside the structured field, an echoed request is not a message.
        let echoedMessage = #"{"error":{"message":"{"instructions":"You are the ForeverLM Assistant"}"}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(echoedMessage.utf8)) == nil)
    }

    @Test("OpenRouter's provider error names the lab and its reason")
    func openRouterProviderErrorNamesTheLab() async {
        let service = AIService()

        // Google AI Studio's 429 on Gemini 3.8 Flash, 2026-09-10: OpenRouter's
        // message is one generic sentence; the lab and the quota reason sit in
        // metadata. Both reach the learner.
        let googleQuota = #"{"error":{"message":"Provider returned error","code":429,"metadata":{"raw":"{\"error\":{\"code\":429,\"message\":\"Resource has been exhausted (e.g. check quota).\",\"status\":\"RESOURCE_EXHAUSTED\"}}","provider_name":"Google AI Studio"}}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(googleQuota.utf8))
            == "Google AI Studio returned an error: Resource has been exhausted (e.g. check quota).")

        // A specific message keeps its wording and gains the lab's name.
        let named = #"{"error":{"message":"Rate limit exceeded","code":429,"metadata":{"provider_name":"Google Vertex","error_type":"rate_limit_exceeded"}}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(named.utf8)) == "Google Vertex: Rate limit exceeded")

        // The raw body is provider-authored: an echoed request in it is dropped
        // while the lab is still named, and a raw sentence is shown as one.
        let echoedRaw = #"{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"{\"messages\":[{\"role\":\"system\",\"content\":\"You are the ForeverLM Assistant\"}]}","provider_name":"OpenAI"}}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(echoedRaw.utf8)) == "OpenAI returned an error")
        let sentenceRaw = #"{"error":{"message":"Provider returned error","code":503,"metadata":{"raw":"The model is overloaded. Please try again later.","provider_name":"Anthropic"}}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(sentenceRaw.utf8))
            == "Anthropic returned an error: The model is overloaded. Please try again later.")

        // Without metadata nothing changes, and a lab name that is itself a
        // payload is not a name.
        let bare = #"{"error":{"message":"Provider returned error","code":429}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(bare.utf8)) == "Provider returned error")
        let payloadName = #"{"error":{"message":"Provider returned error","metadata":{"provider_name":"{\"prompt\":1}"}}}"#
        #expect(await service.extractAPIErrorMessage(from: Data(payloadName.utf8)) == "Provider returned error")

        // The named message still fits the chat's error row.
        let long = String(repeating: "quota ", count: 200)
        let overlong = "{\"error\":{\"message\":\"Provider returned error\",\"metadata\":{\"raw\":\"\(long)\",\"provider_name\":\"Google AI Studio\"}}}"
        let shown = await service.extractAPIErrorMessage(from: Data(overlong.utf8))
        #expect(shown?.hasPrefix("Google AI Studio returned an error: quota") == true)
        #expect((shown?.count ?? 0) <= AIProviderErrorText.maximumLength + 1)
    }

    @Test("Chat extracts only unique ForeverLM source citation tokens")
    @MainActor
    func sourceCitationTokensAreDeterministic() {
        let response = """
        [Grounded source](foreverlm://source/src_abc-123) and
        [the same source](FOREVERLM://SOURCE/src_abc-123), plus
        [encoded source](foreverlm://source/legacy%2D456).
        A moment in a video [talk](foreverlm://source/video-789?t=754) and
        one written as a fragment [talk](foreverlm://source/video-789#t=12m34s).
        An ordinary link https://example.com/source/src_abc-123 is unrelated.
        """

        #expect(ReviewSessionManager.sourceLinkTokensForTesting(response) == [
            "src_abc-123",
            "legacy-456",
            "video-789"
        ])
    }

    @Test("A timed citation names its source and the moment it points at")
    func timedCitationLinksCarryTheirMoment() throws {
        let plain = try #require(URL(string: "foreverlm://source/video-789"))
        #expect(ChatMarkdownView.sourceLink(from: plain) == ChatSourceLink(sourceID: "video-789"))

        let timed = try #require(URL(string: "foreverlm://source/video-789?t=754"))
        #expect(ChatMarkdownView.sourceLink(from: timed) == ChatSourceLink(sourceID: "video-789", seconds: 754))

        // The Dev scheme names the same source, and a query the app already
        // uses beside the moment does not disturb it.
        let dev = try #require(URL(string: "\(ForeverLMRuntimeIdentity.urlScheme)://source/video-789?action=get-transcript&t=1:02:03"))
        #expect(ChatMarkdownView.sourceLink(from: dev) == ChatSourceLink(sourceID: "video-789", seconds: 3723))

        // A deep link may quote the passage it points at; the chat renderer
        // reads the assistant's excerpt off the link title instead, so `q=` is
        // the form for links built by hand or by a tool.
        let quoted = try #require(URL(string: "foreverlm://source/paper-1?q=Energy%20expenditure%20per%20unit%20of%20movement"))
        #expect(ChatMarkdownView.sourceLink(from: quoted) == ChatSourceLink(
            sourceID: "paper-1",
            passage: "Energy expenditure per unit of movement"
        ))
        let blankQuote = try #require(URL(string: "foreverlm://source/paper-1?q=%20%20"))
        #expect(ChatMarkdownView.sourceLink(from: blankQuote) == ChatSourceLink(sourceID: "paper-1"))

        // Every form a model writes after reading a [12:34] marker, and
        // nothing invented for the forms it never should.
        #expect(SourceLinkTimeAnchor.seconds(from: "754") == 754)
        #expect(SourceLinkTimeAnchor.seconds(from: "754s") == 754)
        #expect(SourceLinkTimeAnchor.seconds(from: "12m34s") == 754)
        #expect(SourceLinkTimeAnchor.seconds(from: "1h2m3s") == 3723)
        #expect(SourceLinkTimeAnchor.seconds(from: "12:34") == 754)
        #expect(SourceLinkTimeAnchor.seconds(from: "1:02:03") == 3723)
        #expect(SourceLinkTimeAnchor.seconds(from: "0") == 0)
        #expect(SourceLinkTimeAnchor.seconds(from: "") == nil)
        #expect(SourceLinkTimeAnchor.seconds(from: "soon") == nil)
        #expect(SourceLinkTimeAnchor.seconds(from: "-5") == nil)
        #expect(SourceLinkTimeAnchor.seconds(from: "12:") == nil)
        #expect(SourceLinkTimeAnchor.seconds(from: nil) == nil)
    }

    @Test("A timed citation renders its moment on the marker and under the source")
    @MainActor
    func timedCitationRendersItsMoment() async throws {
        let webView = try await Self.loadedRenderer()
        let markdown = """
        Complex I pumps protons. [Wallace](foreverlm://source/video-789?t=754) \
        ATP synthase lets them back. [Wallace](foreverlm://source/video-789?t=1510) \
        The whole talk is worth it. [Wallace](foreverlm://source/video-789)
        """
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        // The shape `ChatMarkdownView.sourceCardLookupJSON` sends, keyed by the
        // token the page asked about.
        let encodedCards = """
        {"video-789":{"sourceID":"video-789","title":"Mitochondria and Their Roles","subtitle":"Video · PSW Science","kind":"youtube","glyph":"V","thumbnailURL":null}}
        """
        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(encodedCards));")

        let markers = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => link.textContent);"
        ) as? [String])
        // The reply cites one source, so a moment needs no number beside it;
        // the marker with no moment keeps the number, which is all it has.
        #expect(markers == ["12:34", "25:10", "1"])

        let chips = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-moment')).map((chip) => chip.textContent);"
        ) as? [String])
        #expect(chips == ["12:34", "25:10"])

        // One footer entry per source, however many moments of it were cited,
        // and its own link opens the source from the top.
        let footerHrefs = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-link')).map((link) => link.getAttribute('href'));"
        ) as? [String])
        #expect(footerHrefs == ["foreverlm://source/video-789"])
    }

    @Test("In a notebook's chat a source the notebook does not hold is marked, with Add to Notebook beside its row, until its card says it is in")
    @MainActor
    func citationOutsideTheNotebookIsMarked() async throws {
        let webView = try await Self.loadedRenderer()
        let markdown = "Cristae fold the membrane. [Cristae](foreverlm://source/in-1) Supercomplexes sit in them. [Super](foreverlm://source/out-2)"
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        let inCard = ChatSourceCard(article: StudioArticle(url: "https://example.com/in-1", title: "Cristae", sourceType: .paper, id: "in-1")).inNotebook(true)
        let outCard = ChatSourceCard(article: StudioArticle(url: "https://example.com/out-2", title: "Supercomplexes", sourceType: .paper, id: "out-2")).inNotebook(false)
        let cards = try #require(ChatMarkdownView.sourceCardJSON(["in-1": inCard, "out-2": outCard]))
        #expect(!cards.contains("\"outsideNotebook\":null"), "an unmarked card says nothing")
        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(cards));")

        let marked = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => link.classList.contains('source-outside-notebook'));"
        ) as? [Bool])
        #expect(marked == [false, true])
        let label = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.source-citation-marker')[1].getAttribute('aria-label');"
        ) as? String
        #expect(label?.hasSuffix("Not in this notebook") == true)
        let buttons = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-add')).map((button) => [button.textContent, button.dataset.sourceToken]);"
        ) as? [[String]])
        #expect(buttons == [["Add to Notebook", "out-2"]])

        // Added: the host sends the card again, unmarked, and the mark and the button go.
        let added = try #require(ChatMarkdownView.sourceCardJSON(["out-2": outCard.inNotebook(true)]))
        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(added));")
        let after = try #require(try await webView.evaluateJavaScript(
            "[document.querySelectorAll('.source-outside-notebook').length, document.querySelectorAll('.source-footer-add').length];"
        ) as? [Int])
        #expect(after == [0, 0])
    }

    @Test("A reply that cites two sources keeps the number on each moment and page")
    @MainActor
    func citationsOfTwoSourcesKeepTheirNumbers() async throws {
        let webView = try await Self.loadedRenderer()
        let markdown = """
        Complex I pumps protons. [Wallace](foreverlm://source/video-789?t=754) \
        The free-energy change is roughly this. [Chapter 14](foreverlm://source/chapter-14?page=26) \
        ATP synthase lets them back. [Wallace](foreverlm://source/video-789?t=1510)
        """
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        let encodedCards = """
        {"video-789":{"sourceID":"video-789","title":"Mitochondria and Their Roles","subtitle":"Video · PSW Science","kind":"youtube","glyph":"V","thumbnailURL":null},\
        "chapter-14":{"sourceID":"chapter-14","title":"Chapter 14: Energy Conversion","subtitle":"Book · Molecular Biology of the Cell","kind":"book","glyph":"B","thumbnailURL":null}}
        """
        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(encodedCards));")

        let markers = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => link.textContent);"
        ) as? [String])
        #expect(markers == ["1 · 12:34", "2 · p. 26", "1 · 25:10"])
    }

    @Test("A citation chip is tied to the text before it by one word joiner, however often it is redecorated")
    @MainActor
    func citationChipStaysGluedAcrossRedecorations() async throws {
        let webView = try await Self.loadedRenderer()
        // A citation before its period, one after it with no space, and two
        // side by side, the second glued to the first.
        let markdown = """
        Complex I pumps protons [Wallace](foreverlm://source/video-789?t=754). \
        The free-energy change is roughly this.[Chapter 14](foreverlm://source/chapter-14?page=26)[Wallace](foreverlm://source/video-789)
        """
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        let encodedCards = """
        {"video-789":{"sourceID":"video-789","title":"Mitochondria and Their Roles","subtitle":"Video · PSW Science","kind":"youtube","glyph":"V","thumbnailURL":null},\
        "chapter-14":{"sourceID":"chapter-14","title":"Chapter 14: Energy Conversion","subtitle":"Book · Molecular Biology of the Cell","kind":"book","glyph":"B","thumbnailURL":null}}
        """
        // For each chip: its text, the word joiners in the run of text right
        // before it, whether that run ends in one, and the last visible
        // character before the chip.
        let glueScript = """
        (() => {
          const joiner = String.fromCharCode(0x2060);
          return Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => {
            let node = link.previousSibling;
            const glued = node?.nodeType === Node.TEXT_NODE && node.nodeValue.endsWith(joiner);
            let text = '';
            while (node && node.nodeType === Node.TEXT_NODE) {
              text = node.nodeValue + text;
              node = node.previousSibling;
            }
            return [
              link.textContent,
              String(text.split(joiner).length - 1),
              glued ? 'glued' : 'loose',
              text.split(joiner).join('').slice(-1),
            ];
          });
        })();
        """
        let expected = [
            ["1 · 12:34", "1", "glued", "."],
            ["2 · p. 26", "1", "glued", "."],
            ["1", "1", "glued", ""],
        ]

        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(encodedCards));")
        let first = try #require(try await webView.evaluateJavaScript(glueScript) as? [[String]])
        #expect(first == expected)

        // Cards arriving again and a picture lookup answering both redecorate
        // every link; the chips keep exactly one joiner each.
        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(encodedCards));")
        _ = try await webView.evaluateJavaScript("window.setSourceImages({});")
        let again = try #require(try await webView.evaluateJavaScript(glueScript) as? [[String]])
        #expect(again == expected)
    }

    @Test("A citation that turns out invalid gives back the space its chip was glued by")
    @MainActor
    func invalidCitationKeepsItsSpace() async throws {
        let webView = try await Self.loadedRenderer()
        let markdown = "Complex I pumps protons [Wallace](foreverlm://source/BAD-1). "
            + "Then the gradient drives the synthase [Other](foreverlm://source/GOOD-1)."
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        // Drawn as chips first, before any card is known.
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        _ = try await webView.evaluateJavaScript(
            #"window.setSourceCards({"BAD-1": null, "GOOD-1": {"sourceID":"GOOD-1","title":"Good Source","subtitle":"Paper","kind":"paper","glyph":"P","thumbnailURL":null}});"#
        )
        let text = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.source-invalid-link').parentElement.textContent;"
        ) as? String)
        // 2026-09-30 review: the joiner stayed, gluing "protons." to "Unavailable source".
        #expect(text.contains("protons. Unavailable source Then"), "read \(text.debugDescription)")
        // The valid chip keeps its own joiner.
        #expect(text.filter { $0 == "\u{2060}" }.count == 1)
    }

    @Test("A picture written inside a paragraph is lifted out of it, the words either side kept as paragraphs")
    @MainActor
    func pictureInsideAParagraphIsLiftedOut() async throws {
        let webView = try await Self.loadedRenderer()
        let markdown = "Before the picture.\n![The slide](foreverlm://image/video-789/at/695)\nAfter the picture."
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        let shape = try #require(try await webView.evaluateJavaScript("""
        (() => {
          const figure = document.querySelector('figure.source-image-figure');
          const before = figure.previousElementSibling;
          const after = figure.nextElementSibling;
          return [
            figure.parentElement.tagName === 'P' ? 'inside a paragraph' : 'a block',
            (before?.tagName ?? '') + ':' + (before?.textContent ?? '').trim(),
            (after?.tagName ?? '') + ':' + (after?.textContent ?? '').trim(),
            String(document.querySelectorAll('p br').length),
          ];
        })();
        """) as? [String])
        // A block inside a paragraph sat in the prose's measure and squeezed
        // the picture; the line breaks around it go with it.
        #expect(shape == ["a block", "P:Before the picture.", "P:After the picture.", "0"])
    }

    @Test("Copying words from a reply leaves out the joiners that glue its chips, and leaves any other copy alone")
    @MainActor
    func copyLeavesOutTheJoiners() async throws {
        let webView = try await Self.loadedRenderer()
        let markdown = "Complex I pumps protons [Wallace](foreverlm://source/video-789?t=754). Then the synthase turns."
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        let copyScript = """
        (() => {
          const paragraph = document.querySelector('p');
          const range = document.createRange();
          range.selectNodeContents(paragraph);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          const joiner = String.fromCharCode(0x2060);
          const selected = selection.toString();
          const clipboard = new DataTransfer();
          const event = new ClipboardEvent('copy', { clipboardData: clipboard, bubbles: true, cancelable: true });
          document.dispatchEvent(event);
          const plain = clipboard.getData('text/plain');
          const html = clipboard.getData('text/html');
          return [
            selected.includes(joiner) ? 'selection glued' : 'selection plain',
            event.defaultPrevented ? 'rewritten' : 'browser',
            plain.includes(joiner) || html.includes(joiner) ? 'joiner copied' : 'no joiner',
            plain,
          ];
        })();
        """
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        let copied = try #require(try await webView.evaluateJavaScript(copyScript) as? [String])
        #expect(Array(copied.prefix(3)) == ["selection glued", "rewritten", "no joiner"])
        #expect(copied.last?.contains("protons.") == true)

        // Words with no chip are the browser's own copy.
        _ = try await webView.evaluateJavaScript("window.setMarkdown('Plain words, no citation.');")
        let plain = try #require(try await webView.evaluateJavaScript(copyScript) as? [String])
        #expect(plain[1] == "browser")
    }

    @Test("A paged citation shows its page on the marker, the card and under the source")
    @MainActor
    func pagedCitationRendersItsPage() async throws {
        let webView = try await Self.loadedRenderer()
        // The shape of the reply this came from: the page named in prose with
        // its citation beside it, the same chapter cited again without a page,
        // and another chapter standing alone as a card.
        let markdown = """
        The equation is applied to ATP hydrolysis on printed page 836. \
        [Chapter 14](foreverlm://source/chapter-14?page=26 "the free-energy change is roughly") \
        The chapter as a whole is the place to start. [Chapter 14](foreverlm://source/chapter-14)

        [Chapter 2](foreverlm://source/chapter-2?page=19 "The Concentration of Reactants Influences the Free-Energy Change")
        """
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        let encodedCards = """
        {"chapter-14":{"sourceID":"chapter-14","title":"Chapter 14: Energy Conversion","subtitle":"Book · Molecular Biology of the Cell","kind":"book","glyph":"B","thumbnailURL":null},\
        "chapter-2":{"sourceID":"chapter-2","title":"Chapter 2: Cell Chemistry and Bioenergetics","subtitle":"Book · Molecular Biology of the Cell","kind":"book","glyph":"B","thumbnailURL":null}}
        """
        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(encodedCards));")

        let markers = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => link.textContent);"
        ) as? [String])
        // The standalone card is not a numbered citation, so the reply cites
        // one source by number and its page stands alone.
        #expect(markers == ["p. 26", "1"])

        // The hover line names the excerpt and the page before the byline.
        let hover = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.source-citation-marker').getAttribute('title');"
        ) as? String)
        #expect(hover.contains("Page 26"))
        #expect(hover.contains("Chapter 14: Energy Conversion"))

        // One chip per cited page, carrying the page and the excerpt the click flashes.
        let chips = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-page')).map((chip) => [chip.textContent, chip.dataset.sourcePage, chip.dataset.sourcePassage]);"
        ) as? [[String]])
        #expect(chips == [["p. 26", "26", "the free-energy change is roughly"]])

        // The standalone card says its page in the subtitle, where a video card says its moment.
        let cardSubtitle = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('.source-block-card .source-card-subtitle').textContent;"
        ) as? String)
        #expect(cardSubtitle == "Book · Molecular Biology of the Cell · Page 19")

        // The footer row itself still opens the source from the top.
        let footerHrefs = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-link')).map((link) => link.getAttribute('href'));"
        ) as? [String])
        #expect(footerHrefs == ["foreverlm://source/chapter-14"])
    }

    @Test("A lecture's picture takes the link to that lecture beside it as its caption")
    @MainActor
    func sourcePictureTakesItsLinkAsCaption() async throws {
        let webView = try await Self.loadedRenderer()
        let encodedCards = """
        {"video-789":{"sourceID":"video-789","title":"Mitochondria and Their Roles","subtitle":"Video · PSW Science","kind":"youtube","glyph":"V","thumbnailURL":null},\
        "chapter-14":{"sourceID":"chapter-14","title":"Chapter 14: Energy Conversion","subtitle":"Book · Molecular Biology of the Cell","kind":"book","glyph":"B","thumbnailURL":null}}
        """
        let captionScript = """
        (() => {
          const caption = document.querySelector('figure.source-image-figure > figcaption.source-image-caption');
          const link = caption?.querySelector('a');
          return [
            caption ? 'caption' : 'none',
            caption?.querySelector('.source-caption-place')?.textContent ?? '',
            caption?.querySelector('.source-caption-title')?.textContent ?? '',
            link?.getAttribute('href') ?? '',
            String(document.querySelectorAll('.source-block-card').length),
            String(document.querySelectorAll('.source-citation-marker').length),
          ];
        })();
        """
        // A quiz's feedback as saved before 2026-09-28, the tutor's link above
        // the slide, and as ForeverLM writes it now, the slide then the link.
        for markdown in [
            "That was a miss.\n\n[Rewatch 10:54](foreverlm://source/video-789?t=654)\n\n![The slide](foreverlm://image/video-789/at/695)\n\n**Question 18 of 20 · Recall**",
            "That was a miss.\n\n![The slide](foreverlm://image/video-789/at/695)\n\n[Rewatch 10:54](foreverlm://source/video-789?t=654)\n\n---\n\n**Question 18 of 20 · Recall**",
        ] {
            let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
            _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
            _ = try await webView.evaluateJavaScript("window.setSourceCards(\(encodedCards));")
            let found = try #require(try await webView.evaluateJavaScript(captionScript) as? [String])
            // One thing: no card of its own, no citation, the link under the picture.
            #expect(found == [
                "caption", "From 10:54", "Mitochondria and Their Roles",
                "foreverlm://source/video-789?t=654", "0", "0",
            ])
        }

        // A link to another source is not the picture's caption: it stays a card.
        let other = "![The slide](foreverlm://image/video-789/at/695)\n\n[Chapter 14](foreverlm://source/chapter-14?page=26)"
        let encodedOther = try #require(String(data: JSONEncoder().encode(other), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedOther));")
        _ = try await webView.evaluateJavaScript("window.setSourceCards(\(encodedCards));")
        let apart = try #require(try await webView.evaluateJavaScript(captionScript) as? [String])
        #expect(apart.first == "none")
        #expect(apart[4] == "1")
    }

    @Test("A source keeps one number for the whole session and is listed once")
    func citationLedgerNumbersASourceOnceForTheSession() {
        let opening = UUID()
        let middle = UUID()
        let closing = UUID()
        let contexts = ChatCitationLedger.contexts(for: [
            .init(id: opening, markdown: "The payload may stay in the cytosol. [W](foreverlm://source/paper-1)"),
            .init(id: middle, markdown: "Maintain is about the engineered mtDNA. [W](foreverlm://source/paper-1)"),
            .init(
                id: closing,
                markdown: "Transfer moves whole organelles. [W](foreverlm://source/paper-1) [S](foreverlm://source/paper-2)"
            ),
        ])

        // The reply that introduces the paper has nothing above it to suppress.
        #expect(contexts[opening]?.numbers == ["paper-1": 1])
        #expect(contexts[opening]?.presented.isEmpty == true)

        // The next one cites the same work, already listed, and keeps its number.
        #expect(contexts[middle]?.numbers == ["paper-1": 1])
        #expect(contexts[middle]?.presented["paper-1"] == [])

        // A second work takes the next number and is new, so it is listed.
        #expect(contexts[closing]?.numbers == ["paper-1": 1, "paper-2": 2])
        #expect(contexts[closing]?.presented["paper-1"] == [])
        #expect(contexts[closing]?.presented["paper-2"] == nil)
    }

    @Test("A reply still being written receives the whole cast, so citing the session's source lists nothing")
    func citationLedgerHandsTheOpenReplyTheWholeCast() {
        let opening = UUID()
        let streaming = UUID()
        let transcript: [ChatCitationLedger.Entry] = [
            .init(id: opening, markdown: "Lane starts from the Krebs cycle. [L](foreverlm://source/podcast-1?t=754)"),
            .init(id: streaming, markdown: ""),
        ]

        // Judged only by what it has written so far, an empty reply cites
        // nothing and would have no context at all -- and a footer for whatever
        // it goes on to cite.
        #expect(ChatCitationLedger.contexts(for: transcript)[streaming] == nil)

        // Named as the open reply, it knows the podcast is already on screen,
        // under its number, at the moment the first reply pointed at.
        let open = ChatCitationLedger.contexts(for: transcript, open: streaming)[streaming]
        #expect(open?.numbers == ["podcast-1": 1])
        #expect(open?.presented == ["podcast-1": [754]])

        // Once its text has arrived the cast is still there, and a source it
        // introduces itself takes the next number without a presented entry.
        let written = ChatCitationLedger.contexts(
            for: [
                transcript[0],
                .init(id: streaming, markdown: "Compare [L](foreverlm://source/podcast-1) with [P](foreverlm://source/paper-2)"),
            ],
            open: streaming
        )[streaming]
        #expect(written?.numbers == ["podcast-1": 1, "paper-2": 2])
        #expect(written?.presented == ["podcast-1": [754]])
    }

    @Test("The ledger records the moments a transcript has already pointed at")
    func citationLedgerRecordsPresentedMoments() {
        let opening = UUID()
        let repeated = UUID()
        let elsewhere = UUID()
        let whole = UUID()
        let contexts = ChatCitationLedger.contexts(for: [
            .init(id: opening, markdown: "[W](foreverlm://source/video-789?t=754)"),
            .init(id: repeated, markdown: "[W](foreverlm://source/video-789?t=754)"),
            .init(id: elsewhere, markdown: "[W](foreverlm://source/video-789?t=25:10)"),
            .init(id: whole, markdown: "[W](foreverlm://source/video-789)"),
        ])

        #expect(contexts[opening]?.presented["video-789"] == nil)
        // Written as `12:34` or as `754`, it is the same moment.
        #expect(contexts[repeated]?.presented["video-789"] == [754])
        #expect(contexts[elsewhere]?.presented["video-789"] == [754])
        #expect(contexts[whole]?.presented["video-789"] == [754, 1510])
    }

    @Test("A reply lists only the sources the conversation has not introduced")
    @MainActor
    func replyListsOnlySourcesNewToTheConversation() async throws {
        let webView = try await Self.loadedRenderer()
        // The transcript above this reply already listed the paper, and gave the
        // video the second number.
        _ = try await webView.evaluateJavaScript("""
        window.setCitationContext({"numbers": {"paper-1": 1, "video-789": 2}, "presented": {"paper-1": []}});
        """)
        let markdown = """
        Delivery is not the whole story. [Wolfe](foreverlm://source/paper-1) \
        Transfer moves organelles instead. [Wallace](foreverlm://source/video-789)
        """
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        _ = try await webView.evaluateJavaScript("""
        window.setSourceCards({
          "paper-1": {"sourceID": "paper-1", "title": "Precision Mitochondria", "subtitle": "Paper · Nathan Wolfe", "kind": "paper", "glyph": "P", "thumbnailURL": null},
          "video-789": {"sourceID": "video-789", "title": "Mitochondria and Their Roles", "subtitle": "Video · PSW Science", "kind": "youtube", "glyph": "V", "thumbnailURL": null}
        });
        """)

        // Both markers keep the number their source holds for the session.
        let markers = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => link.textContent);"
        ) as? [String])
        #expect(markers == ["1", "2"])

        // Only the source this reply introduces gets a card under it.
        let footerHrefs = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-link')).map((link) => link.getAttribute('href'));"
        ) as? [String])
        #expect(footerHrefs == ["foreverlm://source/video-789"])
    }

    @Test("A reply that cites only what was already listed carries no footer")
    @MainActor
    func replyCitingOnlyPresentedSourcesHasNoFooter() async throws {
        let webView = try await Self.loadedRenderer()
        _ = try await webView.evaluateJavaScript("""
        window.setCitationContext({"numbers": {"paper-1": 1}, "presented": {"paper-1": []}});
        """)
        let markdown = "It has to stay in the cells. [Wolfe](foreverlm://source/paper-1)"
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        _ = try await webView.evaluateJavaScript("""
        window.setSourceCards({"paper-1": {"sourceID": "paper-1", "title": "Precision Mitochondria", "subtitle": "Paper · Nathan Wolfe", "kind": "paper", "glyph": "P", "thumbnailURL": null}});
        """)

        let markers = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => link.textContent);"
        ) as? [String])
        #expect(markers == ["1"])

        // The marker is still a link to the source; the card is what goes.
        let footers = try #require(try await webView.evaluateJavaScript(
            "document.querySelectorAll('.source-citations-footer').length;"
        ) as? Int)
        #expect(footers == 0)
    }

    @Test("A list item a source link opens names that source instead of numbering it")
    @MainActor
    func listItemLedBySourceLinkNamesTheSource() async throws {
        let webView = try await Self.loadedRenderer()
        // The shape of a library search reply (2026-09-30), whose thirteen
        // bullets drew as "[1] — 9 mentions" over a footer repeating them all:
        // a link opening each item, once in bold with a colon, then prose that
        // cites a new source and one the list already named.
        let markdown = """
        **Articles**
        - [Metabolism as Inference](foreverlm://source/article-1) — 9 mentions. Uses the Markov blanket as the basis of conditional independence.
        - **[Gifford Lectures](foreverlm://source/video-2?t=5232)**: 1 mention. The membrane as the blanket.

        The recurring thread is the membrane. [Wolfe](foreverlm://source/paper-1) \
        Lane says it most plainly. [Gifford Lectures](foreverlm://source/video-2)
        """
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        _ = try await webView.evaluateJavaScript("""
        window.setSourceCards({
          "article-1": {"sourceID": "article-1", "title": "Metabolism as Inference - SoTA Letters", "subtitle": "Article · SoTA Letters", "kind": "article", "glyph": "A", "thumbnailURL": null},
          "video-2": {"sourceID": "video-2", "title": "Nick Lane | The Gifford Lectures", "subtitle": "Video · The University of Edinburgh", "kind": "youtube", "glyph": "V", "thumbnailURL": null},
          "paper-1": {"sourceID": "paper-1", "title": "Precision Mitochondria", "subtitle": "Paper · Nathan Wolfe", "kind": "paper", "glyph": "P", "thumbnailURL": null}
        });
        """)

        let entries = try #require(try await webView.evaluateJavaScript("""
        Array.from(document.querySelectorAll('li.source-entry')).map((item) => {
          const link = item.querySelector('a.source-entry-link');
          return [
            link.querySelector('.source-entry-title').textContent,
            link.querySelector('.source-entry-subtitle').textContent,
            link.getAttribute('href'),
            String(link.nextSibling?.nodeValue ?? '').slice(0, 11),
            item.querySelector('strong') ? 'bold' : 'plain',
          ];
        });
        """) as? [[String]])
        // The card's title and byline, the moment on the byline, and the text
        // after the link without the dash or colon that joined it to the title.
        #expect(entries == [
            ["Metabolism as Inference - SoTA Letters", "Article · SoTA Letters", "foreverlm://source/article-1", "9 mentions.", "plain"],
            ["Nick Lane | The Gifford Lectures", "Video · The University of Edinburgh · From 1:27:12", "foreverlm://source/video-2?t=5232", "1 mention. ", "plain"],
        ])

        // Every item is an entry, so the thumbnails stand in for the bullets.
        let listClass = try #require(try await webView.evaluateJavaScript(
            "document.querySelector('ul').className;"
        ) as? String)
        #expect(listClass == "source-entry-list")

        // The citations in the prose are markers, and only the source no entry
        // names is listed underneath: one row per source in the whole reply
        // (product owner, 2026-09-30: "there should just be 13 bulletpoints").
        let markers = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-citation-marker')).map((link) => link.textContent);"
        ) as? [String])
        #expect(markers == ["1", "2"])
        let footerHrefs = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-link')).map((link) => link.getAttribute('href'));"
        ) as? [String])
        #expect(footerHrefs == ["foreverlm://source/paper-1"])
    }

    @Test("A moment no earlier reply pointed at brings the card back")
    @MainActor
    func aNewMomentRelistsAnAlreadyPresentedSource() async throws {
        let webView = try await Self.loadedRenderer()
        _ = try await webView.evaluateJavaScript("""
        window.setCitationContext({"numbers": {"video-789": 1}, "presented": {"video-789": [754]}});
        """)
        let markdown = """
        He says it here. [Wallace](foreverlm://source/video-789?t=754) \
        And again later. [Wallace](foreverlm://source/video-789?t=1510)
        """
        let encodedMarkdown = try #require(String(data: JSONEncoder().encode(markdown), encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.setMarkdown(\(encodedMarkdown));")
        _ = try await webView.evaluateJavaScript("""
        window.setSourceCards({"video-789": {"sourceID": "video-789", "title": "Mitochondria and Their Roles", "subtitle": "Video · PSW Science", "kind": "youtube", "glyph": "V", "thumbnailURL": null}});
        """)

        let footerHrefs = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-link')).map((link) => link.getAttribute('href'));"
        ) as? [String])
        #expect(footerHrefs == ["foreverlm://source/video-789"])

        // The card names both moments this reply cites, not only the new one.
        let chips = try #require(try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.source-footer-moment')).map((chip) => chip.textContent);"
        ) as? [String])
        #expect(chips == ["12:34", "25:10"])
    }

    @Test("Missing source-card lookups encode an explicit null response")
    @MainActor
    func missingSourceCardLookupFailsClosed() async throws {
        let json = try #require(await ChatMarkdownView.sourceCardLookupJSON(
            tokens: ["invented-source-id"],
            sourceCardForToken: { _ in nil }
        ))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["invented-source-id"] is NSNull)
    }

    @Test("Source tool rows never expose internal ids as their label")
    @MainActor
    func sourceToolRowsHideInternalIDs() {
        #expect(ReviewSessionManager.toolArgumentSummaryForTesting([
            "source_id": "5F6D0E7C"
        ]) == nil)
        #expect(ReviewSessionManager.toolArgumentSummaryForTesting([
            "query": "Martin Picard",
            "source_id": "5F6D0E7C"
        ]) == "Martin Picard")
    }

    @Test("Notebook tool rows never expose a Notebook id as their label")
    @MainActor
    func notebookToolRowsHideInternalIDs() {
        // The row waits for the Notebook's name rather than labelling itself
        // with the identifier, in either argument spelling.
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "get_notebook",
            arguments: ["notebook_id": "5C81B8E6-D4B1-4F9E-A1BE-E659923B4603"]
        ) == nil)
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "get_goal",
            arguments: ["goal_id": "5C81B8E6-D4B1-4F9E-A1BE-E659923B4603"]
        ) == nil)
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "add_notebook_sources",
            arguments: [
                "notebook_id": "5C81B8E6-D4B1-4F9E-A1BE-E659923B4603",
                "source_ids": ["5F6D0E7C"]
            ]
        ) == nil)
        // A learner-authored title still labels the row it belongs to.
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "create_notebook",
            arguments: [
                "title": "Mitochondrial phenotyping",
                "notebook_id": "5C81B8E6-D4B1-4F9E-A1BE-E659923B4603"
            ]
        ) == "Mitochondrial phenotyping")
    }

    @Test("Slack read rows name the channel, never its id")
    @MainActor
    func slackReadRowsNameTheChannel() {
        // The call itself carries only an id, which is never a label.
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "read_slack_channel",
            arguments: ["channel_id": "C0123ABCDEF", "since_days": 30]
        ) == nil)
        #expect(ReviewSessionManager.slackChannelDetail(name: nil, arguments: ["channel_id": "C0123ABCDEF"]) == nil)

        // With a name from the channel list, the running row reads as the channel
        // and the window the model asked for.
        #expect(ReviewSessionManager.slackChannelDetail(
            name: "acme-nexus",
            arguments: ["channel_id": "C0123ABCDEF", "since_days": 30]
        ) == "#acme-nexus · 30 days")
        #expect(ReviewSessionManager.slackChannelDetail(
            name: "acme-nexus",
            arguments: ["channel_id": "C0123ABCDEF"]
        ) == "#acme-nexus")
        #expect(ReviewSessionManager.slackChannelDetail(name: "general", sinceDays: 1) == "#general · 1 day")
        // A search row shows what was searched for; a thread row the channel.
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "search_slack_messages",
            arguments: ["query": "alzheimer amyloid", "limit": 20]
        ) == "alzheimer amyloid")
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "read_slack_thread",
            arguments: ["channel_id": "C0123ABCDEF", "thread_ts": "1788740520.000100"]
        ) == nil)

        // The list result teaches the id → name mapping; unnamed channels are skipped.
        let names = ReviewSessionManager.slackChannelNames(inListResult: """
        {"connected":true,"channels":[
          {"channel_id":"C0123ABCDEF","name":"acme-nexus","is_private":false},
          {"channel_id":"C0AAAAAAAAA","name":null,"is_private":null}
        ],"note":"Use read_slack_channel with one of these channel_id values."}
        """)
        #expect(names == ["C0123ABCDEF": "acme-nexus"])

        // The read's own result names the channel too, for a row whose list ran
        // in an earlier session.
        let read = """
        {"channel_id":"C0123ABCDEF","channel_name":"acme-nexus","since_days":7,"thread_count":0,"threads":[]}
        """
        #expect(ReviewSessionManager.slackChannelName(inReadResult: read) == "acme-nexus")
        #expect(ReviewSessionManager.slackSinceDays(inReadResult: read) == 7)
        #expect(ReviewSessionManager.slackChannelName(inReadResult: #"{"channel_id":"C1","channel_name":null}"#) == nil)
    }

    @Test("Source retrieval rows do not expose model-authored queries")
    @MainActor
    func retrievalToolRowsHideQueries() {
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "retrieve_sources",
            arguments: ["query": "static biomarkers abundance versus flux"]
        ) == nil)

        let preview = ReviewSessionManager.toolResultPreviewForTesting(
            toolName: "retrieve_sources",
            result: """
            ## Mitochondrial Phenotyping
            Retrieval reason: Ground the review in source text.
            Query: static biomarkers abundance versus flux

            Dynamic measurements capture physiological changes.
            """
        )
        #expect(!preview.contains("Query:"))
        #expect(preview.contains("## Mitochondrial Phenotyping"))
        #expect(preview.contains("Dynamic measurements"))
    }

    @Test("Search rows describe the filters instead of listing argument names")
    @MainActor
    func searchToolRowsDescribeFiltersNotSchema() {
        // A relative-date lookup ("what was last week's session on?") reaches the
        // tool as filters with no query text. The row used to print the argument
        // *names* — "added_from, added_to, limit, query, source_type, threshold" —
        // which describes the schema rather than the search.
        let dated = ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "search_sources_semantic",
            arguments: [
                "query": "",
                "source_type": "meeting",
                "added_from": "2026-08-17",
                "added_to": "2026-08-24",
                "limit": 8,
                "threshold": 0.2
            ]
        )
        #expect(dated == "meeting · 2026-08-17 – 2026-08-24")

        // A query, when there is one, still speaks for the row on its own.
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "search_sources_semantic",
            arguments: ["query": "Hashimoto thyroiditis somatic mutations", "limit": 8]
        ) == "Hashimoto thyroiditis somatic mutations")

        // Nothing nameable left: no detail beats a list of keys.
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "list_sources",
            arguments: ["limit": 20, "threshold": 0.2]
        ) == nil)

        // One-sided ranges read as ranges, not as a bare date — and a client
        // still calling the filters by the names they shipped with reads the
        // same, rather than losing its row detail to the rename.
        #expect(ReviewSessionManager.toolActivityDetailForTesting(
            toolName: "search_sources_semantic",
            arguments: ["date_from": "2026-08-17"]
        ) == "since 2026-08-17")
    }

    @Test("The working indicator's clock reads as a duration at any length")
    @MainActor
    func workingIndicatorClockFormatsElapsedTime() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func elapsed(_ seconds: TimeInterval) -> String {
            ReviewChatWorkingIndicator.elapsedText(from: start, to: start.addingTimeInterval(seconds))
        }
        #expect(elapsed(0) == "0s")
        #expect(elapsed(7.9) == "7s")
        #expect(elapsed(59) == "59s")
        // Past a minute, seconds stop being a duration anyone reads at a glance.
        #expect(elapsed(60) == "1:00")
        #expect(elapsed(184) == "3:04")
        // A clock adjustment must never render a negative wait.
        #expect(elapsed(-5) == "0s")
    }

    @Test("Retrieval rows present each source as a card with a readable passage")
    func retrievalRowsParseIntoReadablePassages() {
        let result = """
        ## Overview of methods that determine mitochondrial function in human disease (paper, id: src_59cc7b6bc7d6b9c3f2ef1d1d8232de3ff3981e3e2762736e3475f4673d78b31c)
        Retrieval reason: Answer the learner's request about other mitochondrial phenotyping methods in the original paper.
        Query: mitochondrial phenotyping methods

        Overview of methods that determine mitochondrial function in human disease

        ABSTRACT
        Cellular metabolism has a key role in the pathogenesis of human disease. Mitochondria are the
        organelles that
        generate most of the energy needed for a cell to function and drive cellular metabolism.
        Understanding the link
        between metabolic and mitochondrial function can be challenging due to the variation in methods
        used to
        measure mitochondrial function.

        [No exact or semantic passage match was available, so this result contains only the beginning of the source. It does not establish that the query is absent from the omitted text.]

        ---

        ## Mitochondrial Phenotyping (Part 2) (article, id: src_two)
        Added by ForeverLM: you did not ask for this source, but it ranks above one you did for this query. This is a short lead, not a full read.
        Query: mitochondrial phenotyping methods

        Dynamic measurements capture physiological changes.
        """

        let blocks = ReviewSessionManager.parsedRetrievalBlocks(from: result)
        #expect(blocks.count == 2)

        let first = blocks[0]
        #expect(first.sourceID == "src_59cc7b6bc7d6b9c3f2ef1d1d8232de3ff3981e3e2762736e3475f4673d78b31c")
        #expect(first.sourceType == "paper")
        #expect(first.title == "Overview of methods that determine mitochondrial function in human disease")
        #expect(!first.addedByForeverLM)
        // Nothing the model was told leaks into the passage.
        #expect(!first.passage.contains("Retrieval reason"))
        #expect(!first.passage.contains("Query:"))
        #expect(!first.passage.contains("id:"))
        #expect(!first.passage.contains("["))
        // The PDF's hard wraps are gone, the section label keeps its own line.
        #expect(first.passage.contains("Mitochondria are the organelles that generate most of the energy"))
        #expect(first.passage.contains("Understanding the link between metabolic and mitochondrial function"))
        #expect(first.passage.contains("\nABSTRACT\nCellular metabolism"))

        let second = blocks[1]
        #expect(second.sourceID == "src_two")
        #expect(second.sourceType == "article")
        #expect(second.title == "Mitochondrial Phenotyping (Part 2)")
        #expect(second.addedByForeverLM)
        #expect(second.passage == "Dynamic measurements capture physiological changes.")

        // A result without the block header is not a retrieval the card can show.
        #expect(ReviewSessionManager.parsedRetrievalBlocks(from: "Source retrieval failed.\nReason: x").isEmpty)
    }

    @Test("A day listing names its sources, its day and what the learner did")
    func todaySourcesListingReadsTheResult() {
        // The result a tutor got for "quiz me on the videos I watched today".
        let watched = """
        Sources used for watching in ForeverLM for today (2026-09-25): 2 sources.
        To quiz or review them, call start_review_session with the returned source IDs.

        === source_id: src_one ===
        # Mitochondrial Cell Biology 3
        Type: video | Words: 2200
        [0:00] So up till now we saw how mitochondrial membranes are composed.

        === source_id: src_two ===
        # Isolated Mitochondria and Permeabilized Cells/Tissues 2
        """
        let listing = ReviewSessionManager.todaySourcesListing(in: watched)
        #expect(listing.sourceIDs == ["src_one", "src_two"])
        #expect(listing.day == "2026-09-25")
        #expect(listing.title == "What you watched today")

        let pastDay = ReviewSessionManager.todaySourcesListing(
            in: "Sources used for reading in ForeverLM for 2026-09-20: 1 source.\n\n=== source_id: src_a ===\n# A"
        )
        #expect(pastDay.title == "What you read")
        #expect(pastDay.day == "2026-09-20")

        // A planned day keeps the generic row title, and an empty day lists nothing.
        #expect(ReviewSessionManager.todaySourcesListing(
            in: "Pending Schedule sources for today (2026-09-25): 1 source.\n\n=== source_id: src_p ===\n# P"
        ).title == nil)
        let empty = ReviewSessionManager.todaySourcesListing(
            in: "No watching activity was recorded in ForeverLM on today (2026-09-25)."
        )
        #expect(empty.sourceIDs.isEmpty)
    }

    @Test("Unwrapping keeps real paragraphs, headings and lists apart")
    func readablePassageKeepsStructure() {
        let text = """
        1. Introduction
        Mitochondria produce ATP through oxidative phosphorylation, a process that couples electron
        transport to proton pumping across the inner membrane.
        - Complex I
        - Complex II

        A second paragraph stands on its own.
        """
        let passage = ReviewSessionManager.readablePassage(text)
        #expect(passage == """
        1. Introduction
        Mitochondria produce ATP through oxidative phosphorylation, a process that couples electron transport to proton pumping across the inner membrane.
        - Complex I
        - Complex II

        A second paragraph stands on its own.
        """)
    }

    @Test("Read-source rows use the source card instead of raw content")
    @MainActor
    func readSourceToolRowsHideRawContent() {
        let preview = ReviewSessionManager.toolResultPreviewForTesting(
            toolName: "get_source_content",
            result: """
            # Mitochondrial Phenotyping
            Type: article | Words: 4410 | URL: https://example.com/article
            content_sha256: abc123

            Full source text that belongs in model context, not the transcript UI.
            """
        )

        #expect(preview.isEmpty)
    }

    @Test("Review starter rows hide model-only control payloads")
    @MainActor
    func reviewStarterRowsHideModelControlPayloads() {
        let payload = """
        Review session started: Mitochondrial dynamics
        Session ID: INTERNAL-SESSION-ID
        Never show this bookkeeping or review rubric to the learner.
        """

        for toolName in ["start_review_session", "daily_review", "daily_quiz", "memory_review"] {
            #expect(ReviewSessionManager.toolResultPreviewForTesting(
                toolName: toolName,
                result: payload
            ).isEmpty)
        }

        #expect(ReviewSessionManager.toolResultPreviewForTesting(
            toolName: "get_goal",
            result: "Goal: Learn mitochondrial dynamics"
        ) == "Goal: Learn mitochondrial dynamics")
    }

    @Test("Full-library inventory rows show only the count header")
    @MainActor
    func listSourcesRowsHideRawInventory() {
        let preview = ReviewSessionManager.toolResultPreviewForTesting(
            toolName: "list_sources",
            result: """
            Sources (2488):
            Books (22):
            - [book] An Introduction to Systems Biology
              - [chapter] Introduction
            """
        )

        #expect(preview == "Sources (2488):")
    }
}

