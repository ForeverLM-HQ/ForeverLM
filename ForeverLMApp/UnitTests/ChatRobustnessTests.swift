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

    @Test("Chat model selection always includes the default model")
    func enabledChatModelsIncludeDefault() {
        let selected: Set<String> = ["xai|grok-4.5", "openrouter|meta/muse-spark-1.2"]
        let normalized = AIModelCatalog.includingRequiredDefault(
            selected,
            requiredDefaultID: "anthropic|claude-sonnet-5"
        )

        #expect(normalized.contains("anthropic|claude-sonnet-5"))
        #expect(normalized.isSuperset(of: selected))
        #expect(
            AIModelCatalog.includingRequiredDefault(selected, requiredDefaultID: nil) == selected
        )
    }

    @Test("OpenRouter is a transport switch, not a duplicate model catalog")
    func routerModesDoNotDuplicateModels() {
        let openRouterClaude = KeychainService.routedTextSelection(
            provider: .anthropic,
            model: "claude-opus-4-8",
            mode: .openRouter
        )
        #expect(openRouterClaude.provider == .openRouter)
        #expect(openRouterClaude.model == "anthropic/claude-opus-4.8")

        let openRouterOpenAI = KeychainService.routedTextSelection(
            provider: .openai,
            model: "gpt-5.6",
            mode: .openRouter
        )
        #expect(openRouterOpenAI.provider == .openRouter)
        #expect(openRouterOpenAI.model == "openai/gpt-5.6-sol")

        let openRouterLongTail = KeychainService.routedTextSelection(
            provider: .openRouter,
            model: "deepseek/deepseek-v4-pro",
            mode: .openRouter
        )
        #expect(openRouterLongTail.provider == .openRouter)
        #expect(openRouterLongTail.model == "deepseek/deepseek-v4-pro")

        let grok = KeychainService.routedTextSelection(
            provider: .xai,
            model: "grok-4.3",
            mode: .openRouter
        )
        #expect(grok.provider == .openRouter)
        #expect(grok.model == "x-ai/grok-4.3")
    }

    @Test("The server names the text router, OpenRouter is the default, stored choices are preserved")
    func productRoutingOverridesStoredAndCompPreferences() {
        let storedKey = AIModelPreferenceKey.textRoutingMode
        let previousStored = UserDefaults.standard.string(forKey: storedKey)
        let previousRequired = ManagedAI.requiredTextRouterToken
        defer {
            UserDefaults.standard.set(previousStored, forKey: storedKey)
            ManagedAI.requiredTextRouterToken = previousRequired
        }

        // The wire token is a transport name, not this enum's case name.
        #expect(AITextRoutingMode(serverToken: " OpenRouter ") == .openRouter)
        // A router this build does not know names nothing.
        #expect(AITextRoutingMode(serverToken: "otherrouter") == nil)
        // No first-party text transport exists to name.
        #expect(AITextRoutingMode(serverToken: "direct") == nil)
        #expect(AITextRoutingMode(serverToken: "first_party") == nil)
        #expect(AITextRoutingMode(serverToken: "") == nil)

        // The test pins "no own key" rather than reading the developer's
        // Keychain, since an own key names its router itself.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        #expect(AITextRoutingMode.shippedDefault == .openRouter)
        #expect(AITextRoutingMode.allCases == [.openRouter])

        UserDefaults.standard.set(AITextRoutingMode.openRouter.rawValue, forKey: storedKey)
        ManagedAI.requiredTextRouterToken = nil
        #expect(KeychainService.textRoutingMode == .shippedDefault)
        #expect(UserDefaults.standard.string(forKey: storedKey) == AITextRoutingMode.openRouter.rawValue)

        // The account-wide field is the policy, and it reaches a paying account
        // too — not just a comped one. It is stored as named; a router this
        // build does not know (from an older or newer Worker) resolves to
        // the shipped default.
        ManagedAI.applyTextRouterPolicy("otherrouter", comp: nil)
        #expect(ManagedAI.requiredTextRouterToken == "otherrouter")
        #expect(ManagedAI.requiredTextRoutingMode == nil)
        #expect(KeychainService.textRoutingMode == .openRouter)
        #expect(
            KeychainService.routedTextSelection(provider: .anthropic, model: "claude-sonnet-5")
                .provider == .openRouter
        )

        // The whole point of the field: a router switched server-side moves this
        // client's text without a new build, and it still never touches the
        // user's own dormant stored choice.
        ManagedAI.applyTextRouterPolicy("openrouter", comp: nil)
        #expect(ManagedAI.requiredTextRoutingMode == .openRouter)
        #expect(KeychainService.textRoutingMode == .openRouter)
        #expect(
            KeychainService.routedTextSelection(provider: .anthropic, model: "claude-sonnet-5")
                .provider == .openRouter
        )
        #expect(UserDefaults.standard.string(forKey: storedKey) == AITextRoutingMode.openRouter.rawValue)

        // A worker that predates the account-wide field still reports a comp's
        // router, so an older deployment keeps working.
        ManagedAI.applyTextRouterPolicy(
            nil,
            comp: ManagedAI.CompRow(active: true, textRouter: "openrouter", spentThisMonthMicrousd: 0)
        )
        #expect(ManagedAI.requiredTextRoutingMode == .openRouter)

        // An inactive comp block carries no policy, and neither does a response
        // with nothing in it. Both resolve to the shipped default rather than to
        // "route however you like".
        ManagedAI.applyTextRouterPolicy(
            nil,
            comp: ManagedAI.CompRow(active: false, textRouter: "openrouter", spentThisMonthMicrousd: nil)
        )
        #expect(ManagedAI.requiredTextRoutingMode == nil)
        #expect(KeychainService.textRoutingMode == .shippedDefault)

        ManagedAI.applyTextRouterPolicy(nil, comp: nil)
        #expect(ManagedAI.requiredTextRoutingMode == nil)
        #expect(KeychainService.textRoutingMode == .shippedDefault)
        #expect(UserDefaults.standard.string(forKey: storedKey) == AITextRoutingMode.openRouter.rawValue)

        // A token from a newer server than this build is not understood, and must
        // not become "no policy" either.
        ManagedAI.requiredTextRouterToken = "some-router-from-the-future"
        #expect(ManagedAI.requiredTextRoutingMode == nil)
        #expect(KeychainService.textRoutingMode == .shippedDefault)
    }

    @Test("A refused transport is a stale policy, not a dead end")
    func staleTextRouterIsDistinguishedFromOtherRefusals() {
        // The proxy names this code when the account-wide router moved while
        // this client was running. Recovery is re-reading the policy, so it must
        // not be confused with the refusals that mean something else.
        let stale = ManagedAI.ServiceError(
            code: "text_router_required",
            message: "ForeverLM sends ordinary text inference through OpenRouter."
        )
        #expect(stale.isStaleTextRouter)
        #expect(!stale.isCreditsEmpty)
        #expect(!stale.isInvalidSession)

        for other in ["credits_empty", "invalid_session", "model_not_managed", "unknown_path"] {
            #expect(!ManagedAI.ServiceError(code: other, message: "").isStaleTextRouter)
        }
    }

    /// Runs `body` with the managed-AI sign-in state pinned, then restores the
    /// real session. `routedTextConfig` substitutes a credential only while
    /// signed in, so without this the two dispatch tests passed or failed with
    /// whatever the Dev app last did (2026-09-09: green at 18:25, red at 18:37,
    /// no code change). The lock keeps concurrent callers from seeing each
    /// other's pin.
    private static let managedSignInLock = NSLock()
    private func withManagedSignIn(_ signedIn: Bool, _ body: () -> Void) {
        Self.managedSignInLock.lock()
        defer { Self.managedSignInLock.unlock() }
        let saved = ManagedAI.signedInOverrideForTesting
        ManagedAI.signedInOverrideForTesting = signedIn
        defer { ManagedAI.signedInOverrideForTesting = saved }
        body()
    }

    @Test("Dispatch re-routes a direct config after OpenRouter-only is enabled")
    func dispatchReappliesOpenRouterRouting() {
        var stale = AITaskConfig(
            provider: .gemini,
            apiKey: "managed-session",
            model: "gemini-3.5-flash"
        )
        stale.taskLabel = AITask.paperBrowserAgent.rawValue

        withManagedSignIn(true) {
            let routed = KeychainService.routedTextConfig(stale, mode: .openRouter)
            #expect(routed.provider == .openRouter)
            #expect(routed.model == "google/gemini-3.5-flash")
            #expect(routed.apiKey.isEmpty)
            #expect(routed.taskLabel == AITask.paperBrowserAgent.rawValue)
        }

        withManagedSignIn(false) {
            let routed = KeychainService.routedTextConfig(stale, mode: .openRouter)
            #expect(routed.provider == .openRouter)
            #expect(routed.model == "google/gemini-3.5-flash")
            #expect(routed.apiKey == "managed-session")
        }
    }

    @Test("OpenRouter promotion metadata applies to every catalog model generically")
    func openRouterPromotionMetadata() throws {
        let payload = Data(#"""
        {
          "data": [
            {
              "slug": "openai/gpt-5.6-sol",
              "endpoint": { "pricing": { "discount": 0.5 } }
            },
            {
              "slug": "google/gemini-future",
              "endpoint": { "pricing": { "discount": 0.125 } }
            },
            {
              "slug": "invalid/markup",
              "endpoint": { "pricing": { "discount": -0.1 } }
            }
          ]
        }
        """#.utf8)

        let promotions = AIService.openRouterPromotionTable(from: payload)

        #expect(promotions["openai/gpt-5.6-sol"]?.label == "50% off")
        #expect(promotions["openai/gpt-5.6-sol"]?.discountBasisPoints == 5_000)
        // A fractional cut rounds to a whole percent on the badge; the exact
        // figure stays in the basis points for the struck list price.
        #expect(promotions["google/gemini-future"]?.label == "13% off")
        #expect(promotions["google/gemini-future"]?.discountBasisPoints == 1_250)
        #expect(promotions["invalid/markup"] == nil)
    }

    @Test("Which models train comes from each variant's own endpoint in OpenRouter's catalog")
    func openRouterTrainingSlugsReadEachVariant() throws {
        let payload = Data(#"""
        {
          "data": [
            {"slug": "nvidia/nemotron-3-ultra", "endpoint": {
              "model_variant_slug": "nvidia/nemotron-3-ultra:free",
              "data_policy": {"training": true, "retainsPrompts": true}}},
            {"slug": "nvidia/nemotron-3-ultra", "endpoint": {
              "model_variant_slug": "nvidia/nemotron-3-ultra",
              "data_policy": {"training": false, "retainsPrompts": false}}},
            {"slug": "Meta/Muse-Spark-1.3-Contributor", "endpoint": {
              "data_policy": {"training": true}}},
            {"slug": "qwen/qwen3.8-max", "endpoint": null}
          ]
        }
        """#.utf8)
        let rows = AIService.openRouterCatalogRows(from: payload)

        // The free variant is judged by its own host, not the paid model's;
        // a row without a variant slug files under its model's.
        #expect(AIService.openRouterTrainingSlugs(rows: rows) == [
            "nvidia/nemotron-3-ultra:free", "meta/muse-spark-1.3-contributor"
        ])
        // A catalog that carries no data policy anywhere says nothing, so the
        // last answer stands rather than every label clearing.
        let shapeless = AIService.openRouterCatalogRows(from: Data(#"{"data": [{"slug": "a/b", "endpoint": {}}]}"#.utf8))
        #expect(AIService.openRouterTrainingSlugs(rows: shapeless) == nil)
        #expect(AIService.openRouterTrainingSlugs(rows: []) == nil)
    }

    @Test("A :free model's speed is read from its own variant, not the paid hosts'")
    func speedVariantFollowsTheSlug() {
        #expect(OpenRouterModelSpeed.variant(ofSlug: "nvidia/nemotron-3-ultra-550b-a55b:free") == "free")
        #expect(OpenRouterModelSpeed.variant(ofSlug: " Z-AI/GLM-5.3-Flash ") == "standard")
        #expect(OpenRouterModelSpeed.variant(ofSlug: "openrouter/free") == "standard")
        #expect(OpenRouterModelSpeed.variant(ofSlug: "lab/model:") == "standard")
    }

    private static func directoryModel(
        _ id: String,
        maker: String? = nil,
        tools: Bool = true,
        created: TimeInterval? = nil,
        price: (input: Double, output: Double) = (1, 2),
        promotion: RouterModelPromotion? = nil
    ) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id, name: id.split(separator: "/").last.map(String.init) ?? id, makerName: maker,
            inputUSDPerMTokens: price.input, outputUSDPerMTokens: price.output, contextLength: 128_000,
            price: nil, supportsTools: tools, supportsTemperature: nil, supportsVision: nil,
            promotion: promotion,
            createdAt: created.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("Settings › Chat's suggestions resolve to the catalog, then the directory, and wait while it loads")
    func chatModelSuggestions() {
        // A native id is matched by the slug it translates to.
        let opus = AIModelCatalogEntry(maker: .anthropic, provider: .anthropic, modelID: "claude-opus-4-8")
        let entries = [opus]
        let directory = [
            Self.directoryModel("qwen/qwen3.8-omni-flash", maker: "Qwen"),
            Self.directoryModel("lab/toolless", tools: false),
            Self.directoryModel("meta/trains", maker: "Meta")
        ]
        let suggested = [
            "anthropic/claude-opus-4.8", "qwen/qwen3.8-omni-flash", "lab/toolless",
            "meta/trains", "lab/not-listed"
        ]
        let offered: (String) -> Bool = { $0 != "meta/trains" }

        let loaded = ChatModelLists.build(
            suggested: suggested, entries: entries, enabledIDs: [],
            directory: directory, isOffered: offered)
        // A model that cannot call tools, one the learner's settings rule
        // out, and one the loaded directory lacks are left out.
        #expect(loaded.suggestions == [
            .catalog(opus, slug: "anthropic/claude-opus-4.8"),
            .directory(directory[0])
        ])

        // Before the directory answers, an uncatalogued suggestion waits in
        // its place rather than appearing later.
        let loading = ChatModelLists.build(
            suggested: suggested, entries: entries, enabledIDs: [],
            directory: nil, isOffered: offered)
        #expect(loading.suggestions.map(\.slug) == [
            "anthropic/claude-opus-4.8", "qwen/qwen3.8-omni-flash", "lab/toolless", "lab/not-listed"
        ])
        #expect(loading.suggestions[1] == .pending(slug: "qwen/qwen3.8-omni-flash"))
    }

    /// The directory's prices on 2026-09-30.
    @Test("A suggestion shows its family's newest release; Background's only while it stays a tier below Chat's")
    func suggestionsShowNewestRelease() {
        let directory = [
            Self.directoryModel("google/gemini-3.1-flash-lite", maker: "Google", created: 1, price: (0.25, 1.5)),
            Self.directoryModel("google/gemini-3.5-flash-lite", maker: "Google", created: 5, price: (0.3, 2.5)),
            Self.directoryModel("google/gemini-3.8-flash", maker: "Google", created: 9, price: (0.75, 3.75)),
            Self.directoryModel("x-ai/grok-4.3", maker: "xAI", created: 2, price: (1.25, 2.5)),
            Self.directoryModel("x-ai/grok-4.6", maker: "xAI", created: 6, price: (2, 6)),
            Self.directoryModel("x-ai/grok-4.7", maker: "xAI", created: 8, price: (2, 6)),
            Self.directoryModel("x-ai/grok-4.9", maker: "xAI", tools: false, created: 10),
            Self.directoryModel("deepseek/deepseek-v4-flash", maker: "DeepSeek", created: 3, price: (0.08, 0.16)),
            Self.directoryModel("deepseek/deepseek-v4.1-flash", maker: "DeepSeek", created: 7, price: (0.02, 0.4)),
        ]
        let chat = ChatModelLists.build(
            suggested: ["google/gemini-3.5-flash-lite", "x-ai/grok-4.6", "deepseek/deepseek-v4.1-flash"],
            entries: [], enabledIDs: [], directory: directory, isOffered: { _ in true })
        // A release that cannot call tools is no successor in a chat list.
        #expect(chat.suggestions.map(\.slug) == [
            "google/gemini-3.5-flash-lite", "x-ai/grok-4.7", "deepseek/deepseek-v4.1-flash"
        ])

        let chatPicks = ["google/gemini-3.8-flash", "x-ai/grok-4.7", "deepseek/deepseek-v4.1-flash"]
            .compactMap { slug in directory.first { $0.id == slug } }
        let background = ChatModelLists.build(
            suggested: ["google/gemini-3.1-flash-lite", "x-ai/grok-4.3", "deepseek/deepseek-v4-flash"],
            entries: [], enabledIDs: [], directory: directory, isOffered: { _ in true },
            allowsNewerRelease: { ChatModelLists.isTierBelow($0, chatSuggestions: chatPicks) })
        // Gemini's newer Flash Lite still costs less than Chat's Gemini; every
        // Grok after 4.3 costs what Chat's does, and DeepSeek's newer Flash
        // is Chat's own pick.
        #expect(background.suggestions.map(\.slug) == [
            "google/gemini-3.5-flash-lite", "x-ai/grok-4.3", "deepseek/deepseek-v4-flash"
        ])
        // A maker Chat suggests nothing from moves no Background pick.
        #expect(!ChatModelLists.isTierBelow(directory[1], chatSuggestions: []))
    }

    @Test("Settings › Chat's Free list is the slugs it is given, as the catalog or directory carries them")
    func chatModelFreeList() {
        let router = AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: "openrouter/free")
        let gemma = Self.directoryModel("google/gemma-4-31b-it:free", maker: "Google", price: (0, 0))
        let trains = Self.directoryModel("nvidia/nemotron-3-super:free", maker: "NVIDIA", price: (0, 0))
        let directory = [gemma, trains, Self.directoryModel("openrouter/free", price: (0, 0))]

        let built = ChatModelLists.build(
            suggested: ["google/gemma-4-31b-it:free"],
            free: ["openrouter/free", "google/gemma-4-31b-it:free", "nvidia/nemotron-3-super:free", "lab/gone:free"],
            entries: [router],
            enabledIDs: [router.id],
            directory: directory,
            // The Data & Privacy switch hides a free model whose host trains.
            isOffered: { $0 != trains.id })
        // A catalogued pick keeps its catalog row; one Suggested already
        // lists, one the settings rule out, and one OpenRouter dropped go.
        #expect(built.free == [.catalog(router, slug: "openrouter/free")])
        #expect(built.suggestions == [.directory(gemma)])

        // Waiting for the directory, the picks hold their places.
        let loading = ChatModelLists.build(
            suggested: [], free: ["openrouter/free", "google/gemma-4-31b-it:free"],
            entries: [router], enabledIDs: [], directory: nil, isOffered: { _ in true })
        #expect(loading.free == [
            .catalog(router, slug: "openrouter/free"), .pending(slug: "google/gemma-4-31b-it:free")
        ])
    }

    @Test("Settings › Chat's browser narrows to free or discounted models, and counts each")
    func chatModelBrowserFilters() {
        let half = RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil)
        let directory = [
            Self.directoryModel("z-ai/glm-5.3-flash", maker: "Z.ai", created: 2, promotion: half),
            Self.directoryModel("z-ai/glm-5.2", maker: "Z.ai", created: 1),
            Self.directoryModel("nvidia/nemotron-3-ultra:free", maker: "NVIDIA", created: 1, price: (0, 0)),
            Self.directoryModel("stealth/space-bunny", created: 1, price: (0, 0)),
            Self.directoryModel("cohere/free-toolless:free", maker: "Cohere", tools: false, price: (0, 0)),
            Self.directoryModel("cohere/ruled-out:free", maker: "Cohere", price: (0, 0))
        ]
        func build(_ filters: Set<ModelBrowserFilter>) -> ChatModelLists.Built {
            ChatModelLists.build(
                suggested: [], entries: [], enabledIDs: [], directory: directory,
                filters: filters, isOffered: { $0 != "cohere/ruled-out:free" })
        }

        let all = build([])
        #expect(all.makers.map(\.id) == ["maker:zai", "maker:nvidia", "stealth"])
        // Only models the chat could offer count: not one without tools, not
        // one the learner's settings rule out. Zero-priced is free, suffix or not.
        #expect(all.filterCounts == [.free: 2, .discounted: 1])

        let free = build([.free])
        #expect(free.makers.map(\.id) == ["maker:nvidia", "stealth"])
        #expect(free.makers.flatMap(\.models).map(\.id) == ["nvidia/nemotron-3-ultra:free", "stealth/space-bunny"])
        #expect(free.filterCounts == all.filterCounts)

        #expect(build([.discounted]).makers.flatMap(\.models).map(\.id) == ["z-ai/glm-5.3-flash"])
        // Both on list either kind.
        #expect(build([.free, .discounted]).makers.flatMap(\.models).map(\.id) == [
            "z-ai/glm-5.3-flash", "nvidia/nemotron-3-ultra:free", "stealth/space-bunny"
        ])
        #expect(ModelBrowserFilter.phrase([.discounted, .free]) == "free or discounted")
    }

    @Test("Settings › Chat's directory goes by maker, the catalog's makers first, newest model first")
    func chatModelDirectoryMakers() {
        let directory = [
            Self.directoryModel("~anthropic/claude-opus-latest", maker: "Anthropic", created: 2),
            Self.directoryModel("anthropic/claude-new", maker: "Anthropic", created: 3),
            Self.directoryModel("anthropic/claude-old", maker: "Anthropic", created: 1),
            Self.directoryModel("meta-llama/llama-9", maker: "Meta", created: 1),
            Self.directoryModel("meta/muse-9", maker: "Meta", created: 2),
            Self.directoryModel("upstage/solar-1", maker: "Upstage", created: 1),
            Self.directoryModel("upstage/solar-2", maker: "Upstage", created: 2),
            Self.directoryModel("cohere/command", maker: "Cohere", created: 1),
            Self.directoryModel("openrouter/free", created: 1),
            Self.directoryModel("stealth/space-bunny", created: 1),
            Self.directoryModel("cohere/toolless", maker: "Cohere", tools: false),
            Self.directoryModel("cohere/ruled-out", maker: "Cohere")
        ]
        let built = ChatModelLists.build(
            suggested: [], entries: [], enabledIDs: [],
            directory: directory, isOffered: { $0 != "cohere/ruled-out" })

        #expect(built.makers.map(\.id) == [
            "maker:anthropic", "maker:meta", "upstage", "cohere", "maker:other", "stealth"
        ])
        #expect(built.makers.map(\.identity.name) == [
            "Anthropic", "Meta", "Upstage", "Cohere", "OpenRouter", "stealth"
        ])
        // A moving alias files under the maker it points into, and Meta's two
        // vendor slugs are one maker.
        #expect(built.makers[0].models.map(\.id) == [
            "anthropic/claude-new", "~anthropic/claude-opus-latest", "anthropic/claude-old"
        ])
        #expect(built.makers[1].models.map(\.id) == ["meta/muse-9", "meta-llama/llama-9"])
        // The catalog's makers draw their bundled logo; the rest openrouter.ai's.
        #expect(built.makers[0].identity.logo == .anthropic)
        #expect(built.makers[2].identity.logo == nil)
        #expect(built.makers[2].identity.vendor == "upstage")
        #expect(built.makers[3].models.map(\.id) == ["cohere/command"])
    }

    @Test("A promoted row strikes the list price beside the price billed, never the same figure twice")
    func promotionListPriceLabel() {
        func promotion(_ basisPoints: Int) -> RouterModelPromotion {
            RouterModelPromotion(label: "\(basisPoints / 100)% off", discountBasisPoints: basisPoints, endsAt: nil)
        }
        // The directory quotes the discounted price; the list price behind it
        // is what OpenRouter's own page strikes through.
        #expect(promotion(8_000).listPriceLabel(effectiveInput: 0.04, effectiveOutput: 0.15) == "$0.2/$0.75")
        #expect(promotion(5_000).listPriceLabel(effectiveInput: 2, effectiveOutput: 10) == "$4/$20")
        // A fractional cut ("56.10% off") still lands on a clean two-decimal pair.
        #expect(promotion(5_610).listPriceLabel(effectiveInput: 0.58, effectiveOutput: 1.74) == "$1.32/$3.96")
        // Nothing to strike: a free model, a cut too small to move the rounded
        // label, or a promotion outside the (0, 100)% range.
        #expect(promotion(5_000).listPriceLabel(effectiveInput: 0, effectiveOutput: 0) == nil)
        #expect(promotion(100).listPriceLabel(effectiveInput: 0.01, effectiveOutput: 0.01) == nil)
        #expect(promotion(0).listPriceLabel(effectiveInput: 1, effectiveOutput: 2) == nil)
        #expect(promotion(10_000).listPriceLabel(effectiveInput: 1, effectiveOutput: 2) == nil)
    }

    @Test("Disabled and removed chat models cannot become the effective selection")
    func disabledChatModelsAreNotSelectable() throws {
        let muse12 = try #require(AIModelCatalog.entry(
            provider: .meta,
            modelID: AIModelDefaults.latestMuseSpark
        ))
        let claude = try #require(AIModelCatalog.entry(
            provider: .anthropic,
            modelID: AIModelDefaults.defaultAnthropic
        ))
        let enabled = Set([muse12.id])

        #expect(AIModelCatalog.isEnabledChatSelection(
            provider: muse12.provider,
            modelID: muse12.modelID,
            enabledIDs: enabled
        ))
        #expect(!AIModelCatalog.isEnabledChatSelection(
            provider: claude.provider,
            modelID: claude.modelID,
            enabledIDs: enabled
        ))
        // Offered again since 2026-09-14: a stored tick selects it unless the
        // Data & Privacy switch is hiding the models that train.
        #expect(AIModelCatalog.isEnabledChatSelection(
            provider: .meta,
            modelID: AIModelDefaults.museSparkContributor,
            enabledIDs: enabled.union([
                AIModelCatalogEntry(maker: .meta, provider: .meta, modelID: AIModelDefaults.museSparkContributor).id,
            ])
        ) == !AIModelCatalog.hidesTrainingModels)
        #expect(!AIModelCatalog.isEnabledChatSelection(
            provider: .meta,
            modelID: "muse-spark-1.1",
            enabledIDs: enabled
        ))
    }

    @Test("The model picker shows every enabled model on a configured provider")
    func modelPickerShowsEnabledConfiguredModels() throws {
        let claude = try #require(
            AIModelCatalog.entry(
                provider: .anthropic,
                modelID: AIModelDefaults.defaultAnthropic
            )
        )
        let muse = try #require(
            AIModelCatalog.entry(
                provider: .meta,
                modelID: AIModelDefaults.latestMuseSpark
            )
        )
        let llama = try #require(
            AIModelCatalog.entry(
                provider: .openRouter,
                modelID: "meta-llama/llama-4-maverick"
            )
        )
        let groups = [
            AIModelCatalog.MakerGroup(maker: .anthropic, entries: [claude]),
            AIModelCatalog.MakerGroup(maker: .meta, entries: [muse, llama]),
        ]
        let entries = InlineModelPicker.menuEntries(
            groups: groups,
            enabledIDs: [claude.id, muse.id, llama.id],
            configuredProviders: [.anthropic, .meta, .openRouter]
        )

        #expect(entries.map(\.id) == [claude.id, muse.id, llama.id])
        #expect(InlineModelPicker.isEntryAvailable(
            muse,
            configuredProviders: [.anthropic, .meta, .openRouter]
        ))
        #expect(InlineModelPicker.isEntryAvailable(
            claude,
            configuredProviders: [.anthropic, .meta, .openRouter]
        ))
    }

    @Test("An empty picker on a signed-in account never asks for Apple sign-in")
    func emptyPickerNoticeNamesTheRealCause() {
        // The 2026-09-05 report: the session is valid and the menu was blank.
        #expect(InlineModelPicker.emptyMenuNotice(hasConfiguredProviders: true) == .noModelsAvailable)
        // Only a Mac with no usable provider — no managed session — is told to sign in.
        #expect(InlineModelPicker.emptyMenuNotice(hasConfiguredProviders: false) == .signInRequired)
    }

    @Test("The model chip names the effort: the pick, else the model's own, and none for a model without one")
    func modelChipNamesTheEffort() {
        let offered: [AIEffort] = [.low, .medium, .high]
        #expect(InlineModelPicker.chipEffort(selected: nil, supported: offered, modelDefault: .medium) == .medium)
        #expect(InlineModelPicker.chipEffort(selected: .high, supported: offered, modelDefault: .medium) == .high)
        // A pick the model does not take is not sent, so the chip names the default.
        #expect(InlineModelPicker.chipEffort(selected: .max, supported: offered, modelDefault: .medium) == .medium)
        #expect(InlineModelPicker.chipEffort(selected: .high, supported: [], modelDefault: .medium) == nil)
    }

    @Test("Retired Muse Spark selections are rejected instead of substituted")
    func retiredMuseSparkSelectionIsRejected() {
        let isRetired = AIModelDefaults.isRetiredChatModel(
            provider: .openRouter,
            model: AIModelDefaults.retiredOpenRouterMuseSpark
        )

        #expect(isRetired)
        #expect(
            AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.latestMuseSpark) != nil
        )
    }

    @Test("Muse Spark Contributor is offered again and flagged as training on every route")
    func museSparkContributorTrainsOnInputs() {
        // Retired 2026-09-10 while the router's account refused it; back on
        // 2026-09-14 — The product owner wants it "even if they train on my data" — with
        // the Data & Privacy switch as the way to keep it out of the pickers.
        // Not retired on any route, flagged on both, and the full tier is not.
        #expect(!AIModelDefaults.isRetiredChatModel(
            provider: .meta,
            model: AIModelDefaults.museSparkContributor
        ))
        #expect(!AIModelDefaults.isRetiredChatModel(
            provider: .openRouter,
            model: "meta/\(AIModelDefaults.museSparkContributor)"
        ))
        #expect(AIModelDefaults.isRetiredChatModel(
            provider: .openRouter,
            model: AIModelDefaults.retiredOpenRouterMuseSpark
        ))
        #expect(AIModelDefaults.trainsOnInputs(
            provider: .meta,
            model: AIModelDefaults.museSparkContributor
        ))
        #expect(AIModelDefaults.trainsOnInputs(
            provider: .openRouter,
            model: "meta/\(AIModelDefaults.museSparkContributor)"
        ))
        #expect(!AIModelDefaults.trainsOnInputs(
            provider: .meta,
            model: AIModelDefaults.latestMuseSpark
        ))
        #expect(AIModelDefaults.preferredMeta == [AIModelDefaults.latestMuseSpark, AIModelDefaults.museSparkContributor])
        #expect(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.latestMuseSpark) != nil)
    }

    @Test("Chat distinguishes Apple sign-in from an unavailable managed model")
    func chatConfigurationErrorsNameTheMissingRequirement() {
        #expect(
            ReviewSessionManager.chatConfigFailureMessageForTesting(
                isSignedIn: false,
                provider: .meta
            ) == "Sign in with Apple to use ForeverLM AI."
        )
        #expect(
            ReviewSessionManager.chatConfigFailureMessageForTesting(
                isSignedIn: true,
                provider: .meta
            ) == "The selected chat model isn't available. Choose another model, or check your OpenRouter key in AI Usage (the sidebar's OpenRouter button)."
        )
        #expect(
            !ReviewSessionManager.chatConfigFailureMessageForTesting(
                isSignedIn: true,
                provider: .openRouter
            ).contains("Sign in with Apple")
        )
    }

    @Test("Reasoning opt-out asks first-generation GPT-5 models for minimal effort, not none")
    func lowestReasoningEffortRespectsMandatoryReasoningModels() {
        // OpenRouter rejects `none` for these with a 400: "Reasoning is
        // mandatory for this endpoint and cannot be disabled."
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5-nano") == "minimal")
        #expect(AIService.lowestReasoningEffort(model: "gpt-5-mini") == "minimal")
        #expect(AIService.lowestReasoningEffort(model: "gpt-5") == "minimal")
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5-2025-08-07") == "minimal")
        // Later generations, chat-tuned variants, and other vendors accept none.
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5.6-luna") == "none")
        #expect(AIService.lowestReasoningEffort(model: "gpt-5.1") == "none")
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-5-chat-latest") == "none")
        #expect(AIService.lowestReasoningEffort(model: "anthropic/claude-sonnet-5") == "none")
        // GPT-6 rejects none and minimal; low is its documented floor.
        #expect(AIService.lowestReasoningEffort(model: "gpt-6-astra") == "low")
        #expect(AIService.lowestReasoningEffort(model: "openai/gpt-6-astra") == "low")
    }

    @Test("A refused reasoning opt-out is recognised and the model asks for low from then on")
    func mandatoryReasoningRefusalIsRememberedPerModel() {
        let body = Data(#"{"error":{"message":"Reasoning is mandatory for this endpoint and cannot be disabled.","code":400}}"#.utf8)
        #expect(AIService.isMandatoryReasoningRefusal(status: 400, body: body))
        #expect(!AIService.isMandatoryReasoningRefusal(status: 429, body: body))
        #expect(!AIService.isMandatoryReasoningRefusal(status: 400, body: Data(#"{"error":{"message":"Bad request"}}"#.utf8)))

        let slug = "test-vendor/mandatory-reasoning-\(UUID().uuidString)"
        #expect(AIService.lowestReasoningEffort(model: slug) == "none")
        AIService.MandatoryReasoningModels.insert(slug)
        #expect(AIService.lowestReasoningEffort(model: slug) == "low")
        #expect(AIService.lowestReasoningEffort(model: slug.uppercased()) == "low")
    }

    @Test("A paper parked behind a refused reasoning opt-out resumes on its own")
    func mandatoryReasoningCleanupFailureResumes() {
        let message = StudioArticle.paperContentCleanupFailureMessage(
            "Reasoning is mandatory for this endpoint and cannot be disabled. [OpenRouter request failed (400)]"
        )
        #expect(PaperContentPreparationService.isTransientIngestionFailure(message))
    }

    @Test("Every GPT-5-and-later gate reads one generation number")
    func openAIGenerationDrivesTheReasoningGates() {
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-5") == 5)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-5.6-sol") == 5)
        #expect(AIModelDefaults.openAIGeneration(of: "openai/gpt-5.6-luna") == 5)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-6-astra") == 6)
        #expect(AIModelDefaults.openAIGeneration(of: " OpenAI/GPT-6-Astra ") == 6)
        // Names that merely start with digits are not generations of the line.
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-4o") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-4o-mini-transcribe") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-image-2") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "gpt-oss-120b") == nil)
        #expect(AIModelDefaults.openAIGeneration(of: "claude-sonnet-5") == nil)

        // The gates that used to spell "gpt-5" each follow the number, bare or
        // routed, so Astra inherits the reasoning-model request shape.
        for model in ["gpt-6-astra", "openai/gpt-6-astra", "gpt-5.6-sol"] {
            #expect(AIService.openAIModelRequiresDefaultTemperature(model))
        }
        #expect(!AIService.openAIModelRequiresDefaultTemperature("gpt-4o"))

        // Astra's and the GPT-5.6 line's budget is their 922k input cap, not
        // the 1.05M window that includes output; GPT-5.5 documents no input
        // cap, so its budget is the 1.05M window; gpt-4o is 128k.
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-6-astra") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-6-astra") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-5.6-sol") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-5.6") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-5.5") == 1_050_000)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-4o") == 128_000)

        // The same lab models reached through OpenRouter keep the lab's
        // published window (the input cap, where the lab states one; OpenRouter
        // lists the 1.05M total), whichever spelling the slug uses.
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-5.6-sol") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-6-astra") == 922_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "anthropic/claude-opus-4.8") == 1_000_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-sonnet-4-5-20250929") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "google/gemini-3.5-flash") == 1_048_576)

        // The 2026-09-07 audit of the pinned table against the labs' pages and
        // OpenRouter's directory: Claude Opus 4 is a 200k model (only Sonnet 4
        // of that generation has 1M), under its bare name, its "-0" alias and
        // its dated snapshot alike; Together serves Inkling at 524k, half the
        // model's own window, so the host's figure is the budget there.
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-4") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-4-0") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-4-20250514") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "anthropic/claude-opus-4") == 200_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-sonnet-4-0") == 1_000_000)
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-sonnet-4") == 1_000_000)
        #expect(AIService.contextWindowTokens(provider: .together, model: "thinkingmachines/inkling") == 524_288)
        #expect(AIService.contextWindowTokens(provider: .together, model: "thinkingmachines/inkling-nvfp4") == 524_288)
    }

    @Test("A context window is published, directory-listed, or unknown — never a default")
    func contextWindowNeverDefaults() {
        let openRouterKey = AIModelCatalog.openRouterContextLengthKey
        let defaults = UserDefaults.standard
        let savedOpenRouter = defaults.data(forKey: openRouterKey)
        defer {
            if let savedOpenRouter {
                defaults.set(savedOpenRouter, forKey: openRouterKey)
            } else {
                defaults.removeObject(forKey: openRouterKey)
            }
        }
        defaults.removeObject(forKey: openRouterKey)

        // Nothing published and no directory row: unknown, not a neighbour's
        // figure and not a per-host constant.
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "moonshotai/kimi-k2.6") == nil)
        #expect(AIService.contextWindowTokens(provider: .openai, model: "gpt-4.1-mini") == nil)
        #expect(AIService.contextWindowTokens(provider: .xai, model: "grok-4.5") == nil)
        #expect(AIService.contextWindowTokens(provider: .cerebras, model: "zai-glm-4.7") == nil)

        // OpenRouter's directory answers for every slug it serves — and for a
        // closed-lab model the published table omits, on the lab's own route.
        AIModelCatalog.cacheOpenRouterContextLengths([
            "moonshotai/kimi-k2.6": 262_144,
            "openai/gpt-oss-120b": 131_072,
            "x-ai/grok-4.5": 2_000_000,
        ])
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "moonshotai/kimi-k2.6") == 262_144)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "openai/gpt-oss-120b") == 131_072)
        #expect(AIService.contextWindowTokens(provider: .xai, model: "grok-4.5") == 2_000_000)
        #expect(AIService.contextWindowTokens(provider: .openRouter, model: "x-ai/grok-4.5") == 2_000_000)

        // With no window there is nothing to fit to: the budgeter leaves the
        // request exactly as built instead of trimming against a guess.
        let system = String(repeating: "s", count: 600_000)
        let unbudgeted = AIService.budgetedChatRequest(
            provider: .xai,
            model: "grok-4.6-unlisted",
            system: system,
            messages: [(role: "user", content: "hi")],
            requestedMaxTokens: 9_000
        )
        #expect(unbudgeted.system.count == system.count)
        #expect(unbudgeted.maxTokens == 9_000)
        #expect(AIService.inputCharacterBudget(provider: .xai, model: "grok-4.6-unlisted", requestedMaxTokens: 9_000) == nil)
        #expect(AIService.cappedResponseTokens(provider: .xai, model: "grok-4.6-unlisted", requestedMaxTokens: 9_000) == 9_000)
    }

    @Test("resident source budget follows the selected model's context window")
    func sourceContextBudgetFollowsContextWindow() throws {
        // A dropped-in book used to stop at 64k characters whatever the model.
        // The budget is now a share of the model's input budget, so a
        // million-token window holds more than a 256k one, and both hold more
        // than the old constant.
        let millionWindow = try #require(AIService.sourceContextCharacterBudget(
            provider: .anthropic, model: "claude-opus-5", requestedMaxTokens: 8_000
        ))
        let quarterMillionWindow = try #require(AIService.sourceContextCharacterBudget(
            provider: .openai, model: "gpt-5.6-sol", requestedMaxTokens: 8_000
        ))
        #expect(millionWindow >= quarterMillionWindow)
        #expect(quarterMillionWindow > 64_000)

        // The share is capped: half of a million-token window is ~400k tokens
        // resent every round, and one cold cache rewrite of it cost $2.65.
        let input = try #require(AIService.inputCharacterBudget(
            provider: .anthropic, model: "claude-opus-5", requestedMaxTokens: 8_000
        ))
        let ceiling = AIService.sourceContextMaxTokens * AIService.approxCharsPerToken
        #expect(input / 2 > ceiling)
        #expect(millionWindow == ceiling)
        #expect(quarterMillionWindow <= ceiling)

        // No published window: nothing to derive from, so the caller keeps its
        // standing figure instead of budgeting against a guess.
        #expect(AIService.sourceContextCharacterBudget(
            provider: .xai, model: "grok-4.6-unlisted", requestedMaxTokens: 8_000
        ) == nil)
    }

    @Test("A failure at the proxy is named after ForeverLM, not the provider")
    func unreachableServiceIsNamedHonestly() throws {
        // What a sinkholed or down proxy actually produces: a URLError whose
        // failing URL is ForeverLM's, for a request the provider never saw.
        let proxied = URLError(
            .timedOut,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey:
                    "https://ai.foreverlm.com/v1/proxy/openrouter/api/v1/chat/completions"
            ]
        )
        var renamed: String?
        if case AIError.serviceUnreachable(let text) = ManagedAI.namingUnreachableService(proxied) {
            renamed = text
        }
        #expect(renamed?.contains("ai.foreverlm.com") == true)
        #expect(renamed?.contains("never got to the AI provider") == true)
        // Retrying is still right — the rename must not change what the error
        // is, only what it says it is.
        #expect(AITransientErrorClassifier.isTransient(AIError.serviceUnreachable(renamed ?? "")))

        // The same failure against the provider itself, as the direct rail
        // produces, is the provider's to own and passes through untouched.
        let direct = URLError(
            .timedOut,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://openrouter.ai/api/v1/chat/completions"]
        )
        #expect(ManagedAI.namingUnreachableService(direct) is URLError)

        // A refusal the proxy answered with is a real answer, not an
        // unreachable service.
        let refused = AIError.httpError(status: 401, message: "Sign in again.", retryAfterSeconds: nil)
        #expect(ManagedAI.namingUnreachableService(refused) is AIError)
        #expect(!AITransientErrorClassifier.isTransient(refused))
    }

    @Test("An own OpenRouter key sends the call straight to OpenRouter")
    func ownOpenRouterKeyBypassesTheProxy() throws {
        ManagedAI.ownKeyOverrideForTesting = .some(
            ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key")
        )
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.setValue("Bearer ", forHTTPHeaderField: "Authorization")
        ManagedAI.rewrite(&request)

        #expect(request.url?.host == "openrouter.ai")
        #expect(request.url?.path == "/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test-key")
        // The proxy's own header would be a live credential handed to a party
        // that has no use for it.
        #expect(request.value(forHTTPHeaderField: ManagedAI.ownKeyHeader) == nil)
        // Attribution is for ForeverLM's ledger, which is local on this rail.
        // What the learner is studying is not OpenRouter's business.
        for header in [
            "X-ForeverLM-Task",
            "X-ForeverLM-Source-Title",
            "X-ForeverLM-Subject-ID",
            "X-ForeverLM-Subject-Type",
            "X-ForeverLM-Activity-ID",
            "X-ForeverLM-Platform",
            "X-ForeverLM-Build"
        ] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }

        // Only that key's own router leaves the proxy. Any other host ends at
        // the proxy's deliberate 404, and the key does not travel with it.
        var elsewhere = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        ManagedAI.rewrite(&elsewhere)
        #expect(elsewhere.url?.host == ManagedAI.baseURL.host)
        #expect(elsewhere.url?.path == "/v1/proxy/unsupported")
        #expect(elsewhere.value(forHTTPHeaderField: ManagedAI.ownKeyHeader) == nil)
        for (_, value) in elsewhere.allHTTPHeaderFields ?? [:] {
            #expect(!value.contains("sk-or-test-key"))
        }
    }

    @Test("With no own key every provider request still ends at the proxy")
    func withoutAnOwnKeyEverythingIsProxied() throws {
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        #expect(!ManagedAI.sendsOwnKeyDirect(toHost: "openrouter.ai"))
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        ManagedAI.rewrite(&request)
        #expect(request.url?.host == ManagedAI.baseURL.host)
        #expect(request.url?.path == "/v1/proxy/openrouter/api/v1/chat/completions")
    }

    @Test("A lab's own API has no proxy route, and its query never reaches the proxy")
    func labHostsEndAtTheUnsupportedRoute() throws {
        // OpenRouter is the proxy's only upstream since 2026-10-02. The hosts
        // that once had a route of their own now end where any unknown host
        // does, carrying nothing of their URL, not even a `?key=`.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }

        for url in [
            "https://api.openai.com/v1/audio/speech",
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:streamGenerateContent?alt=sse&key=stray-key",
            "https://api.meta.ai/v1/chat/completions",
            "https://api.x.ai/v1/images/generations",
            "https://api.example.com/v1/anything?api_key=stray-key",
        ] {
            var request = URLRequest(url: URL(string: url)!)
            ManagedAI.rewrite(&request)
            #expect(request.url?.host == ManagedAI.baseURL.host)
            #expect(request.url?.path == "/v1/proxy/unsupported")
            #expect(request.url?.query == nil)
        }

        // OpenRouter's own query passes through whole.
        var lookup = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/generation?id=gen-1")!)
        ManagedAI.rewrite(&lookup)
        #expect(lookup.url?.path == "/v1/proxy/openrouter/api/v1/generation")
        #expect(lookup.url?.query == "id=gen-1")
    }

    @Test("The direct rail asks OpenRouter for the cost the proxy would have priced")
    func directRailRequestsBilledCost() throws {
        var proxied: [String: Any] = [
            "model": "openai/gpt-oss-120b",
            "messages": [["role": "user", "content": "Hello"]]
        ]
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        AIService.applyOpenRouterPayloadExtras(&proxied, provider: .openRouter)
        #expect(proxied["usage"] == nil)

        var direct: [String: Any] = [
            "model": "openai/gpt-oss-120b",
            "messages": [["role": "user", "content": "Hello"]]
        ]
        ManagedAI.ownKeyOverrideForTesting = .some(
            ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key")
        )
        AIService.applyOpenRouterPayloadExtras(&direct, provider: .openRouter)
        #expect((direct["usage"] as? [String: Bool])?["include"] == true)
    }

    @Test("Claude and GPT on the learner's own OpenRouter key are pinned to their lab's endpoint, so BYOK applies")
    func ownKeyLabModelsRunOnTheirLabEndpoint() throws {
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        func body(_ model: String) -> [String: Any] {
            ["model": model, "messages": [["role": "user", "content": "Hello"]] as [[String: Any]]]
        }

        ManagedAI.ownKeyOverrideForTesting = .some(ManagedAI.OwnKey(router: .openRouter, key: "sk-or-test-key"))
        var claude = body("anthropic/claude-opus-5.5")
        AIService.applyOpenRouterPayloadExtras(&claude, provider: .openRouter)
        let routing = try #require(claude["provider"] as? [String: Any])
        #expect(routing["order"] as? [String] == ["anthropic"])
        #expect(routing["allow_fallbacks"] as? Bool == false)
        #expect(routing["only"] == nil)

        // A GPT model OpenAI serves itself runs on OpenAI's endpoint, not
        // Azure or Bedrock, so an OpenAI key added to OpenRouter applies.
        // Slugs of this test's own: other suites clear the shared cache.
        func tier(_ tag: String, _ host: String) -> OpenRouterEndpointTier {
            OpenRouterEndpointTier(
                tag: tag, providerName: host, inputUSDPerMTokens: 1, outputUSDPerMTokens: 4,
                cachedInputUSDPerMTokens: nil, discount: nil
            )
        }
        OpenRouterEndpointTierCatalog.cache(
            [tier("azure", "Azure"), tier("openai", "OpenAI"), tier("amazon-bedrock/global", "Amazon Bedrock")],
            for: "openai/byok-test-gpt"
        )
        var gpt = body("openai/byok-test-gpt")
        AIService.applyOpenRouterPayloadExtras(&gpt, provider: .openRouter)
        let gptRouting = try #require(gpt["provider"] as? [String: Any])
        #expect(gptRouting["order"] as? [String] == ["openai"])
        #expect(gptRouting["allow_fallbacks"] as? Bool == false)

        // OpenAI's open weights run only on other hosts: the throughput route stays.
        OpenRouterEndpointTierCatalog.cache([tier("groq", "Groq"), tier("deepinfra/bf16", "DeepInfra")], for: "openai/byok-test-oss")
        var openWeights = body("openai/byok-test-oss")
        AIService.applyOpenRouterPayloadExtras(&openWeights, provider: .openRouter)
        #expect((openWeights["provider"] as? [String: Any])?["order"] == nil)

        // An OpenAI model whose endpoints were never read is OpenAI's own and
        // is pinned too; its open weights are not.
        var unread = body("openai/byok-test-unread")
        AIService.applyOpenRouterPayloadExtras(&unread, provider: .openRouter)
        #expect((unread["provider"] as? [String: Any])?["order"] as? [String] == ["openai"])
        var unreadOSS = body("openai/gpt-oss-byok-test")
        AIService.applyOpenRouterPayloadExtras(&unreadOSS, provider: .openRouter)
        #expect((unreadOSS["provider"] as? [String: Any])?["order"] == nil)

        // Another lab's model keeps the throughput route.
        var other = body("deepseek/deepseek-v4.1-flash")
        AIService.applyOpenRouterPayloadExtras(&other, provider: .openRouter)
        #expect((other["provider"] as? [String: Any])?["order"] == nil)

        // A Speed tier names its own endpoint and is left alone.
        var pinned = body("anthropic/claude-opus-5.5")
        pinned["provider"] = ["order": ["anthropic/fast"], "allow_fallbacks": false] as [String: Any]
        AIService.pinLabModelToItsOwnEndpoint(&pinned)
        #expect((pinned["provider"] as? [String: Any])?["order"] as? [String] == ["anthropic/fast"])

        // No own key: the proxy's rail keeps OpenRouter's routing.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        var proxied = body("anthropic/claude-opus-5.5")
        AIService.applyOpenRouterPayloadExtras(&proxied, provider: .openRouter)
        #expect((proxied["provider"] as? [String: Any])?["order"] == nil)
    }

    @Test("A subsidized account may pick its makers' models and the free ones; any other pick runs on the substitute")
    func subsidizedModelAccess() throws {
        let json = Data(#"{"makers":["anthropic","openai"],"free_models":true}"#.utf8)
        let access = try JSONDecoder().decode(AIModelAccess.self, from: json)
        #expect(access == AIModelAccess(makers: ["anthropic", "openai"], freeModels: true))
        for slug in ["anthropic/claude-opus-5.5", "OpenAI/gpt-6.1-terra", "openrouter/free", "meta-llama/llama-4:free"] {
            #expect(access.allows(slug: slug), "\(slug)")
        }
        for slug in ["google/gemini-2.5-flash", "deepseek/deepseek-v4-flash", "nvidia/parakeet-tdt-0.6b-v3", "claude-opus-5.5"] {
            #expect(!access.allows(slug: slug), "\(slug)")
        }
        #expect(access.permitted("deepseek/deepseek-v4-flash") == AIModelAccess.substituteSlug)
        #expect(access.permitted("anthropic/claude-opus-5.5") == "anthropic/claude-opus-5.5")
        #expect(access.permitted("nvidia/parakeet-tdt-0.6b-v3", substitute: AIModelDefaults.batchTranscription)
            == AIModelDefaults.batchTranscription)
        // The substitutes are themselves covered.
        #expect(access.allows(slug: AIModelAccess.substituteSlug))
        #expect(access.allows(slug: AIModelDefaults.batchTranscription))
        // Without free models only the makers remain.
        #expect(!AIModelAccess(makers: ["anthropic"], freeModels: false).allows(slug: "openrouter/free"))
    }

    @Test("A first-party lab has no text endpoint; Muse Spark's text travels OpenRouter")
    func firstPartyLabsHaveNoTextEndpoint() throws {
        // The labs are model families on the routers. ForeverLM sends their
        // own hosts nothing, so a text call that skipped routing fails loudly.
        for provider in [AIProvider.anthropic, .openai, .gemini, .xai, .meta] {
            #expect(AIService.openAICompatibleChatEndpoint(for: provider) == nil)
            #expect(!AIService.routesThroughOpenRouter(provider))
        }
        #expect(AIService.routesThroughOpenRouter(.openRouter))
        #expect(
            AIService.openAICompatibleChatEndpoint(for: .openRouter)
                == "https://openrouter.ai/api/v1/chat/completions"
        )
        let routed = KeychainService.routedTextSelection(
            provider: .meta,
            model: "muse-spark-1.2",
            mode: .openRouter
        )
        #expect(routed.provider == .openRouter)
        #expect(routed.model == "meta/muse-spark-1.2")

        // Offered again; hidden only while the Data & Privacy switch is on.
        #expect(
            (AIModelCatalog.entry(
                provider: .meta,
                modelID: AIModelDefaults.museSparkContributor
            ) != nil) == !AIModelCatalog.hidesTrainingModels
        )
        #expect(
            AIService.contextWindowTokens(
                provider: .meta,
                model: AIModelDefaults.museSparkContributor
            ) == 1_048_576
        )
    }

    @Test("OpenRouter GPT-5 requests omit unsupported temperature")
    func openRouterGPT5OmitsTemperature() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Extract paper metadata."],
            ["role": "user", "content": "Front matter"],
        ]
        let luna = try AIService.prepareOpenAICompatiblePayload(
            [
                "model": "openai/gpt-5.6-luna",
                "messages": messages,
                "max_tokens": 4_096,
                "temperature": 0.0,
            ],
            provider: .openRouter
        )
        #expect(luna["model"] as? String == "openai/gpt-5.6-luna")
        #expect(luna["temperature"] == nil)
        #expect(luna["max_tokens"] as? Int == 4_096)

        let deepSeek = try AIService.prepareOpenAICompatiblePayload(
            [
                "model": "deepseek/deepseek-v4-pro",
                "messages": messages,
                "max_tokens": 4_096,
                "temperature": 0.0,
            ],
            provider: .openRouter
        )
        #expect(deepSeek["temperature"] as? Double == 0.0)
    }

    @Test("Claude Opus 5 is the offered flagship with its admitted OpenRouter slug")
    func opusFiveCatalogAndRouting() {
        #expect(AIModelDefaults.latestClaude == "claude-opus-5")
        #expect(AIModelDefaults.preferredAnthropic.contains("claude-opus-5"))
        #expect(!AIModelDefaults.preferredAnthropic.contains("claude-opus-4-8"))
        #expect(
            OpenRouterModelID.slug(provider: .anthropic, model: "claude-opus-5")
                == "anthropic/claude-opus-5"
        )
        // Speed never changes the slug: OpenRouter's fast tier is a separate
        // endpoint of the same model, chosen through `provider.order`, so the
        // model id and its prompt cache stay shared across speeds.
        #expect(
            OpenRouterModelID.slug(provider: .anthropic, model: "claude-opus-5")
                == "anthropic/claude-opus-5"
        )
        #expect(AIService.contextWindowTokens(provider: .anthropic, model: "claude-opus-5") == 1_000_000)
    }

    // MARK: - Transient error classification

    @Test("Network blips are transient")
    func networkErrorsAreTransient() {
        #expect(AITransientErrorClassifier.isTransient(URLError(.timedOut)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.networkConnectionLost)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.cannotConnectToHost)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.notConnectedToInternet)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.dnsLookupFailed)))
    }

    @Test("User-initiated cancellation is never transient")
    func cancellationIsNotTransient() {
        #expect(!AITransientErrorClassifier.isTransient(URLError(.cancelled)))
        #expect(!AITransientErrorClassifier.isTransient(CancellationError()))
    }

    @Test("Rate limits and overloaded providers are transient")
    func providerPressureIsTransient() {
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (429).")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (529).")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("OpenAI request failed (503).")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("overloaded_error: Overloaded")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("Rate limit reached for requests")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("The server had an internal error while processing your request.")))
    }

    @Test("Permanent failures are not retried")
    func permanentFailuresAreNotTransient() {
        #expect(!AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (401).")))
        #expect(!AITransientErrorClassifier.isTransient(AIError.apiError("invalid x-api-key")))
        #expect(!AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (400).")))
        #expect(!AITransientErrorClassifier.isTransient(AIError.missingAPIKey))
        #expect(!AITransientErrorClassifier.isTransient(AIError.invalidResponse))
        #expect(!AITransientErrorClassifier.isTransient(AIError.outputTokenLimit("hit max_tokens")))
    }

    @Test("Quota refusals are told apart from connection failures")
    func rateLimitsAreDistinguishedFromNetworkErrors() {
        // Retried, but on the server's timescale and never described as a
        // connection problem — the two are separate questions.
        #expect(AITransientErrorClassifier.isRateLimited(
            AIError.httpError(status: 429, message: "Too many ForeverLM AI requests this hour.", retryAfterSeconds: 900)
        ))
        #expect(AITransientErrorClassifier.isRateLimited(AIError.apiError("Anthropic chat request failed (429).")))
        #expect(AITransientErrorClassifier.isRateLimited(AIError.apiError("Rate limit reached for requests")))

        #expect(!AITransientErrorClassifier.isRateLimited(URLError(.networkConnectionLost)))
        #expect(!AITransientErrorClassifier.isRateLimited(AIError.apiError("OpenAI request failed (503).")))
        #expect(!AITransientErrorClassifier.isRateLimited(AIError.apiError("overloaded_error: Overloaded")))
    }

    @Test("Retry-After survives on the typed error so backoff can honour it")
    func retryAfterIsCarriedOnTypedErrors() {
        let error = AIError.httpError(status: 429, message: "Too many requests.", retryAfterSeconds: 1_800)
        #expect(AITransientErrorClassifier.retryAfterSeconds(error) == 1_800)
        // A wait this long outlasts the retry budget, so the chat loop surfaces
        // the server's message instead of sleeping through three attempts.
        #expect(1_800 > AITransientErrorClassifier.maximumRetryAfterWait)
        // A 429 carrying no hint has nothing to key that decision on, so it
        // keeps the ordinary backoff — upstream provider limits clear in seconds.
        #expect(AITransientErrorClassifier.retryAfterSeconds(AIError.apiError("429")) == nil)
    }

    @Test("Managed proxy credit errors preserve their structured identity")
    func managedCreditsEmptyEnvelope() throws {
        let data = Data(#"{"error":{"code":"credits_empty","message":"ForeverLM AI credits are empty — top up in Settings to continue."}}"#.utf8)
        let error = try #require(ManagedAI.serviceError(from: data))

        #expect(error.isCreditsEmpty)
        #expect(error.code == "credits_empty")
        #expect(error.message.contains("top up in Settings"))
    }

    @Test("Background work has explicit text and multimodal default routes")
    func backgroundDefaultRoutesAreExplicit() {
        #expect(KeychainService.defaultBackgroundTaskRoute.provider == .openRouter)
        #expect(KeychainService.defaultBackgroundTaskRoute.model == AIModelDefaults.defaultOpenRouter)
        #expect(KeychainService.defaultBackgroundMultimodalTaskRoute.provider == .openRouter)
        #expect(
            KeychainService.defaultBackgroundMultimodalTaskRoute.model
                == AIModelDefaults.visionOpenRouter
        )
        #expect(KeychainService.modelSupportsVision(
            provider: .gemini,
            model: AIModelDefaults.latestGemini
        ) == true)
        #expect(KeychainService.modelSupportsVision(
            provider: .openRouter,
            model: AIModelDefaults.defaultOpenRouter
        ) == false)
    }

    // MARK: - Rolling history digest in the chat payload

    private func alternatingMessages(count: Int) -> [(role: String, content: String)] {
        (0..<count).map { index in
            (
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "TURN-\(index) message body"
            )
        }
    }

    @Test("Digest carries folded turns; compact transcript covers the unfolded rest")
    @MainActor
    func digestAndUnfoldedRemainderShareTheEarlierTranscript() {
        let payload = ReviewSessionManager.historyDigestPayloadForTesting(
            messages: alternatingMessages(count: 26),
            digest: "DIGEST-MARKER: learner is studying spaced repetition.",
            coveredMessageCount: 4,
            systemPrompt: "SYSTEM"
        )

        #expect(payload.system.contains("DIGEST-MARKER"))
        #expect(payload.system.contains("Turns since that summary:"))
        // Turns 4 and 5 aged out of the recent window but are not folded yet —
        // the deterministic compact must still carry them.
        #expect(payload.system.contains("TURN-4"))
        #expect(payload.system.contains("TURN-5"))
        // Folded turns are represented only by the digest.
        #expect(!payload.system.contains("TURN-0"))
        // The recent window still goes to the provider verbatim.
        #expect(payload.messages.contains { $0.content.contains("TURN-25") })
    }

    @Test("Fully folded older history is carried by the digest alone")
    @MainActor
    func fullyFoldedHistoryUsesDigestOnly() {
        let payload = ReviewSessionManager.historyDigestPayloadForTesting(
            messages: alternatingMessages(count: 26),
            digest: "DIGEST-MARKER only.",
            coveredMessageCount: 6,
            systemPrompt: "SYSTEM"
        )

        #expect(payload.system.contains("DIGEST-MARKER"))
        #expect(!payload.system.contains("Turns since that summary:"))
    }

    @Test("Without a digest the deterministic compact covers all older turns")
    @MainActor
    func emptyDigestFallsBackToDeterministicCompact() {
        let payload = ReviewSessionManager.historyDigestPayloadForTesting(
            messages: alternatingMessages(count: 26),
            digest: "",
            coveredMessageCount: 0,
            systemPrompt: "SYSTEM"
        )

        #expect(payload.system.contains("Earlier transcript compact:"))
        #expect(payload.system.contains("TURN-0"))
        #expect(!payload.system.contains("Turns since that summary:"))
    }

    // MARK: - Tool-result trim fallback

    @Test("Trim keeps the most recent whole entries and drops the oldest")
    @MainActor
    func trimKeepsRecentEntriesDropsOldest() {
        let separator = "\n\n---\n\n"
        let context = ["OLDEST-ENTRY", "MIDDLE-ENTRY", "RECENT-ENTRY"].joined(separator: separator)

        let trimmed = ReviewSessionManager.trimmedToolResultEntriesForTesting(context, budget: 140)

        #expect(trimmed.contains("[Earlier tool results dropped because the complete request exceeded this model's context window.]"))
        #expect(trimmed.contains("RECENT-ENTRY"))
        #expect(trimmed.contains("MIDDLE-ENTRY"))
        #expect(!trimmed.contains("OLDEST-ENTRY"))
    }

    @Test("A single oversized entry keeps its identifying head")
    @MainActor
    func oversizedSingleEntryKeepsTail() {
        let entry = "HEAD-" + String(repeating: "x", count: 100) + "-TAIL"

        let trimmed = ReviewSessionManager.trimmedToolResultEntriesForTesting(entry, budget: 135)

        #expect(trimmed.contains("HEAD-"))
        #expect(!trimmed.contains("-TAIL"))
    }

    // MARK: - Typed HTTP errors

    @Test("HTTP failures classify by status code, not message wording")
    func httpErrorsClassifyByStatus() {
        #expect(AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 429, message: "custom provider wording", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 529, message: "anything", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 503, message: "anything", retryAfterSeconds: nil)))
        #expect(!AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 401, message: "rate limit mentioned but auth failed", retryAfterSeconds: nil)))
        #expect(!AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 400, message: "bad request", retryAfterSeconds: nil)))
    }

    @Test("Retry-After hint is surfaced from typed HTTP errors")
    func retryAfterHintSurfaces() {
        #expect(AITransientErrorClassifier.retryAfterSeconds(
            AIError.httpError(status: 429, message: "slow down", retryAfterSeconds: 12)) == 12)
        #expect(AITransientErrorClassifier.retryAfterSeconds(
            AIError.apiError("slow down")) == nil)
    }

    @Test("Retry-After header parses delta-seconds and HTTP-dates")
    func retryAfterHeaderParses() throws {
        let url = try #require(URL(string: "https://api.example.com"))
        let seconds = try #require(HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "7"]
        ))
        #expect(AIService.retryAfterSeconds(from: seconds) == 7)

        let none = try #require(HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil, headerFields: [:]
        ))
        #expect(AIService.retryAfterSeconds(from: none) == nil)

        let malformed = try #require(HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "not-a-date"]
        ))
        #expect(AIService.retryAfterSeconds(from: malformed) == nil)
    }

    // MARK: - Context-overflow classification

    @Test("Context-window overflows are recognized as recoverable")
    func contextOverflowIsRecognized() {
        #expect(AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 400, message: "prompt is too long: 210000 tokens > 200000 maximum", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 400, message: "This model's maximum context length is 128000 tokens.", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isContextOverflow(
            AIError.apiError("context_length_exceeded: reduce your prompt")))
        #expect(!AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 401, message: "context length irrelevant, invalid key", retryAfterSeconds: nil)))
        #expect(!AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 400, message: "invalid tool schema", retryAfterSeconds: nil)))
    }

    // MARK: - Native tool support

    @Test("Native-tool rejections are recognized for text-protocol fallback")
    func nativeToolRejectionRecognized() {
        #expect(AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 400, message: "tools is not supported for this model", retryAfterSeconds: nil)))
        #expect(AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 422, message: "unknown parameter: 'tools'", retryAfterSeconds: nil)))
        // Server errors are transient, not a protocol rejection.
        #expect(!AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 500, message: "tools backend crashed", retryAfterSeconds: nil)))
        // Tool-unrelated 4xx must not disable native tools.
        #expect(!AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 400, message: "temperature must be between 0 and 2", retryAfterSeconds: nil)))
    }

    @Test("A malformed tool round-trip is not read as a missing capability")
    func malformedToolRoundTripIsNotANativeToolRejection() {
        // The 400 that stranded sessions on the text protocol: it names an item
        // of the conversation we sent, and says "function_call" and "invalid"
        // while doing it. The fix is a better request, not a worse protocol.
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "Item 'fc_049a726c405dbe46006a963a3b56fc87d1ad5b46d254ac4c00' of type 'function_call' was provided without its required 'reasoning' item: 'rs_049a726c405dbe46006a963a39687087d186afccbcb4a5ac77'. (all 2 candidates failed: openai:gpt-5.6-sol:flex 400 invalid_request_error) [AI provider stream request failed (400)]",
            retryAfterSeconds: nil
        )))
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "Invalid value for 'tool_call_id': no tool call with that id was found.",
            retryAfterSeconds: nil
        )))
        // A schema we built wrongly is our bug too, not a capability gap.
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "Invalid schema for function 'search_sources_semantic': 'date_from' is not of type object.",
            retryAfterSeconds: nil
        )))
        // The bare word "tool" in unrelated prose decides nothing.
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "The requested toolkit image is not available in this region.",
            retryAfterSeconds: nil
        )))
        // Real refusals still land, however each provider words them.
        #expect(AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400, message: "tool_choice is not supported by this model", retryAfterSeconds: nil)))
        #expect(AINativeToolSupport.isNativeToolRejection(AIError.apiError(
            "This model does not support function calling.")))
    }

    // MARK: - Native tool-call stream accumulation

    @Test("OpenAI-style tool_calls deltas accumulate arguments by index")
    func openAIStyleToolCallAccumulates() {
        var accumulator = AIToolCallStreamAccumulator()
        accumulator.consume([
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "id": "call_x1",
                    "function": ["name": "get_schedule", "arguments": "{\"da"],
                ]]],
            ]],
        ])
        accumulator.consume([
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "function": ["arguments": "te\": \"2026-07-16\"}"],
                ]]],
            ]],
        ])
        accumulator.consume([
            "choices": [["finish_reason": "tool_calls", "delta": [:]]],
        ])

        #expect(accumulator.sawToolUseStop)
        let calls = accumulator.toolCalls
        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_x1")
        #expect(calls.first?.name == "get_schedule")
        #expect(calls.first?.arguments["date"] as? String == "2026-07-16")
    }

    @Test("Malformed tool arguments degrade to an empty dictionary, not a crash")
    func malformedToolArgumentsDegradeGracefully() {
        let call = AIToolCallRequest(id: "call_1", name: "list_sources", argumentsJSON: "{broken json")
        #expect(call.arguments.isEmpty)
    }

    // MARK: - Native tool protocol payloads

    @Test("OpenAI-style messages carry tool role replies with matching call ids")
    func openAIStyleToolMessagePairing() {
        let call = AIToolCallRequest(id: "call_9", name: "get_app_context", argumentsJSON: "{}")
        let messages = AIService.openAIStyleToolMessages(system: "SYSTEM", turns: [
            .user("What's my context?"),
            .assistant(text: "", toolCalls: [call]),
            .toolResults([AIToolResultPayload(callID: "call_9", toolName: "get_app_context", text: "Notebook X", isError: true)]),
        ])

        #expect(messages.first?["role"] as? String == "system")
        let assistant = messages[2]
        let toolCalls = assistant["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.first?["id"] as? String == "call_9")
        let toolReply = messages[3]
        #expect(toolReply["role"] as? String == "tool")
        #expect(toolReply["tool_call_id"] as? String == "call_9")
    }

    @Test("A learner turn with pictures becomes image parts on the OpenRouter shape")
    func attachedPicturesBecomeImageParts() {
        let picture = AIChatImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), mediaType: "image/jpeg")
        let turns: [AIChatTurn] = [
            .user("What is this?", images: [picture]),
            .assistant(text: "A JPEG header.", toolCalls: []),
            .user("", images: [picture]),
        ]

        // OpenAI-style chat completions: image_url parts then a text part.
        let openAI = AIService.openAIStyleToolMessages(system: "S", turns: turns)
        let openAIParts = openAI[1]["content"] as? [[String: Any]]
        #expect(openAIParts?[0]["type"] as? String == "image_url")
        #expect((openAIParts?[0]["image_url"] as? [String: Any])?["url"] as? String == picture.dataURL)
        #expect(openAIParts?[1]["text"] as? String == "What is this?")
        #expect((openAI[3]["content"] as? [[String: Any]])?.count == 1)

        // A turn without pictures is still the plain string every route sent before.
        #expect(AIService.openAIStyleToolMessages(system: "S", turns: [.user("Just text")])[1]["content"] as? String == "Just text")
        #expect(AIService.projectedCharacterCount(of: turns) > AIChatImage.projectedCharacterCount * 2)
    }

    // MARK: - Native mode prompt and specs

    @Test("Native system prompt drops the text tool-call protocol")
    @MainActor
    func nativePromptOmitsTextProtocol() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            synthesisTitle: "Notebook"
        )

        #expect(!prompt.contains("<flm_tool_call>"))
        #expect(!prompt.contains("input_schema:"))
        #expect(prompt.contains("<attached_sources>"))
        #expect(prompt.contains("add_to_synthesis"))
        #expect(prompt.contains("read-before-write"))
        #expect(prompt.contains("- Never name a tool or tell the learner which tool you would call; say what you did or what they can do in the app."))
    }

    @Test("A chat on one source tells the model not to cite that source")
    @MainActor
    func singleSourceChatDoesNotCiteItsSource() {
        let tools: [ReviewSessionManager.AppToolDefinition] = [
            .init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"),
        ]
        let one = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: true,
            appTools: tools
        )
        #expect(one.contains("This chat is about that one attached source"))
        #expect(one.contains("Do not cite it"))
        #expect(one.contains("The one exception is a chat opened on a single attached source"))

        let two = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: true,
            attachedSourceCount: 2,
            appTools: tools
        )
        #expect(!two.contains("This chat is about that one attached source"))
        #expect(two.contains("Cite a source from the learner's library"))

        let none = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: false,
            appTools: tools
        )
        #expect(!none.contains("This chat is about that one attached source"))
    }

    @Test("Chat on a route with a native web engine has web search attached directly")
    @MainActor
    func chatPromptWithNativeWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            webSearch: .native
        )

        #expect(prompt.contains("ForeverLM app tools available"))
        #expect(prompt.contains("Live web search is available: the provider's web_search tool is attached"))
        #expect(prompt.contains("search the library first"))
        // 2026-09-09: a question about "the last Huberman Lab podcast" went to the
        // web although the episode was in the library, because the prompt framed
        // the web as the place for external-sounding questions.
        #expect(prompt.contains("Search the web only if the library has nothing applicable"))
        #expect(prompt.contains("holds podcasts, videos, articles, books and papers"))
        #expect(!prompt.contains("Web search is unavailable"))
        #expect(!prompt.contains("request_web_search"))
        #expect(!prompt.contains("Deep Research is enabled"))
        #expect(prompt.contains("targeted paper, title, author, keyword, or topic lookup"))
        #expect(prompt.contains("Call list_sources only when the learner explicitly asks"))
    }

    @Test("Chat on an Exa-fallback route reaches the web through request_web_search")
    @MainActor
    func chatPromptWithOnRequestWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            webSearch: .onRequest
        )

        #expect(prompt.contains("Live web search is available on request"))
        #expect(prompt.contains("call request_web_search with one focused query"))
        #expect(prompt.contains("Only if the library has nothing applicable"))
        #expect(!prompt.contains("Web search is unavailable"))
        #expect(!prompt.contains("Deep Research is enabled"))
    }

    @Test("Chat on a route without a billable web engine says so and points at the model picker")
    @MainActor
    func chatPromptWithoutWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")]
        )

        #expect(prompt.contains("Web search is unavailable on this model route"))
        #expect(prompt.contains("pick another model in the composer"))
        #expect(!prompt.contains("request_web_search"))
        #expect(!prompt.contains("choose Deep Research"))
    }

    @Test("Chat offers to add papers the library lacks when it carries the importer")
    @MainActor
    func chatPromptOffersToImportPapers() {
        let importer = ReviewSessionManager.AppToolDefinition(
            name: "import_paper_from_url",
            description: "Import a paper",
            inputSchemaJSON: "{\"type\":\"object\"}"
        )
        let withImporter = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: false,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"), importer],
            webSearch: .native
        )
        #expect(withImporter.contains("Papers outside the library"))
        #expect(withImporter.contains("say so and offer to add it"))
        #expect(withImporter.contains("call import_paper_from_url"))
        #expect(withImporter.contains("Never ask the learner to paste a URL"))

        let withoutImporter = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: false,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            webSearch: .native
        )
        #expect(!withoutImporter.contains("Papers outside the library"))
    }

    @Test("Chat web access follows the engine on the route the request travels")
    @MainActor
    func chatWebSearchAccessFollowsRoute() {
        typealias Manager = ReviewSessionManager
        // First-party routes carry the provider's own tool; idle it is free.
        #expect(Manager.webSearchAccess(selectedProvider: .anthropic, routedProvider: .anthropic, routedModel: "claude-sonnet-5") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .openai, routedProvider: .openai, routedModel: "gpt-5.6-sol") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .xai, routedProvider: .xai, routedModel: "grok-4") == .native)
        // Under the OpenRouter transport policy the slug decides the engine:
        // native for the labs OpenRouter documents, Exa (one billed search per
        // request) for everything else — so those ask first.
        #expect(Manager.webSearchAccess(selectedProvider: .openai, routedProvider: .openRouter, routedModel: "openai/gpt-5.6-sol") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .anthropic, routedProvider: .openRouter, routedModel: "anthropic/claude-sonnet-5") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .openRouter, routedProvider: .openRouter, routedModel: "deepseek/deepseek-v3.2") == .onRequest)
        #expect(Manager.webSearchAccess(selectedProvider: .nvidia, routedProvider: .openRouter, routedModel: "nvidia/nemotron-3-super") == .onRequest)
        // Gemini's search allowance is account-wide, whatever the transport.
        #expect(Manager.webSearchAccess(selectedProvider: .gemini, routedProvider: .gemini, routedModel: "gemini-3-pro") == .unavailable)
        #expect(Manager.webSearchAccess(selectedProvider: .gemini, routedProvider: .openRouter, routedModel: "google/gemini-3-pro") == .unavailable)
    }

    @Test("Deep Research uses its research prompt and enables live web search")
    @MainActor
    func deepResearchPromptEnablesWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "mtDNA mutations and CHIP",
            hasAttachedSource: false,
            mode: .deepResearch,
            webSearch: .native
        )

        #expect(prompt.contains("ForeverLM's research agent"))
        #expect(prompt.contains("interactive Deep Research chat"))
        #expect(prompt.contains("Research notes: <topic>"))
        #expect(prompt.contains("fetch_web_page"))
        #expect(prompt.contains("Deep Research is enabled"))
        #expect(prompt.contains("attached to every step of this turn"))
        #expect(!prompt.contains("Web search is unavailable"))
        #expect(!prompt.contains("Live web search is available:"))
        #expect(!prompt.contains("request_web_search"))
    }

    @Test("Reading modes encode selective and comprehensive source-reading contracts")
    @MainActor
    func readingModePromptsStayDistinct() {
        let shallow = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "AlphaGo",
            hasAttachedSource: true,
            mode: .shallowRead
        )
        let deep = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "AlphaGo",
            hasAttachedSource: true,
            mode: .deepRead
        )

        #expect(shallow.contains("acquire the gestalt"))
        #expect(shallow.contains("Be deliberately selective"))
        #expect(shallow.contains("Distinguish what the source claims"))
        #expect(!shallow.contains("Work in layers"))
        #expect(deep.contains("Work in layers"))
        #expect(deep.contains("mechanisms step by step"))
        #expect(deep.contains("what remains unread or unresolved"))
        #expect(!deep.contains("live web-search tool proactively"))
    }

    @Test("An unknown figure label sends the model to show_source_image, not the web")
    @MainActor
    func figureLabelNotFoundPointsAtShowSourceImage() {
        // The real case: a paper whose main figures are indexed, asked for a
        // supplementary label that is printed in a file the library does not
        // hold. Listing the labels and stopping there let the model conclude
        // the picture was not on this Mac and search the web for it.
        let labelled = ReviewSessionManager.figureLabelNotFoundMessage(
            requested: "Figure S17",
            availableLabels: ["Figure 1", "Figure 2", "Figure 8"]
        )
        #expect(labelled.contains("Figure S17 was not found"))
        #expect(labelled.contains("Figure 1, Figure 2, Figure 8"))
        #expect(labelled.contains("show_source_image"))
        #expect(labelled.contains("page"))
        #expect(labelled.contains("Do not search the web"))

        // The branch that already named the fallback keeps naming it.
        let unlabelled = ReviewSessionManager.figureLabelNotFoundMessage(
            requested: "Figure 3",
            availableLabels: []
        )
        #expect(unlabelled.contains("no structurally labelled figures"))
        #expect(unlabelled.contains("show_source_image"))
        #expect(!unlabelled.contains("labelled figures are:"))
    }

    @Test("Asking for a panel crops the figure to that panel")
    @MainActor
    func paperFigurePanelCropZoomsToThePanel() {
        // Figure 1 of the single-cell mtDNA paper as the vision pass stored it:
        // a figure rectangle and one rectangle per lettered panel. Before this,
        // panel_label picked the panel's explanation but the picture stayed the
        // whole figure, so "zoom in on 1A" could not be answered with a picture.
        let figureRect = PaperFigureRect(x: 0.16, y: 0.04, width: 0.68, height: 0.6)
        let panelA = PaperFigurePanel(
            id: "fig-panel-1", label: "A", explanation: "Workflow schematic.",
            rect: PaperFigureRect(x: 0.1646, y: 0.0401, width: 0.2139, height: 0.2659)
        )
        let panelB = PaperFigurePanel(
            id: "fig-panel-2", label: "B", explanation: "Read fraction distribution.",
            rect: PaperFigureRect(x: 0.3516, y: 0.041, width: 0.1568, height: 0.1304)
        )
        let unmeasured = PaperFigurePanel(id: "fig-panel-3", label: "C", explanation: "Histogram.", rect: nil)
        let analysis = PaperFigureAnalysis(
            summary: "Validation of single-cell mtDNA sequencing.",
            visualEvidence: [],
            figureRect: figureRect,
            panels: [panelA, panelB, unmeasured],
            analysisVersion: PaperFigureAnalysis.currentVersion,
            generatedAt: Date()
        )

        // Every spelling the model uses for a panel finds the bare letter.
        for spelling in ["A", "a", "(a)", "1a", "Figure 1A", "Fig. 1a", "panel a"] {
            #expect(ReviewSessionManager.paperFigurePanel(labelled: spelling, in: analysis)?.id == panelA.id, "\(spelling)")
        }
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "b", in: analysis)?.id == panelB.id)
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "", in: analysis) == nil)
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "Figure 1", in: analysis) == nil)
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "z", in: analysis) == nil)

        // The crop is the panel's rectangle when it has one, the figure's when
        // it does not, and never widens to the page.
        #expect(ReviewSessionManager.paperFigureCrop(analysis: analysis, panel: panelA) == panelA.rect)
        #expect(ReviewSessionManager.paperFigureCrop(analysis: analysis, panel: unmeasured) == figureRect)
        #expect(ReviewSessionManager.paperFigureCrop(analysis: analysis, panel: nil) == figureRect)

        // The tool tells the model that panel_label zooms, so a panel-by-panel
        // walk through a figure is one call per panel rather than a guess.
        let specs = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true, appTools: [], hasSynthesisContext: false
        )
        let inspect = specs.first { $0.name == "inspect_paper_figure" }
        #expect(inspect?.description.contains("cropped to that panel") == true)
        // With the paper beside the chat the figure is outlined there, not
        // copied into the reply (product owner, 2026-09-22).
        #expect(inspect?.description.contains("outlined on its page there") == true)
        let properties = inspect?.inputSchema["properties"] as? [String: Any]
        let panelProperty = properties?["panel_label"] as? [String: Any]
        #expect((panelProperty?["description"] as? String)?.contains("zoomed") == true)
    }

    @Test("The picture tools take any library source and are offered without an attached source")
    @MainActor
    func pictureToolsReachTheWholeLibrary() {
        // The 2026-09-12 case: the paper was in the library, a search had just
        // found it, and both tools refused its ID as "not attached" until the
        // model gave up and opened the publisher's page in the browser.
        let detached = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false
        )
        let names = detached.map(\.name)
        #expect(names.contains("inspect_paper_figure"))
        #expect(names.contains("show_source_image"))
        #expect(!names.contains("retrieve_sources"))
        #expect(!names.contains("extract_video_slides"))

        let inspect = detached.first { $0.name == "inspect_paper_figure" }
        #expect(inspect?.description.contains("does not have to be attached") == true)
        #expect(inspect?.description.contains("never open the publisher's page") == true)
        let inspectSource = (inspect?.inputSchema["properties"] as? [String: Any])?["source_id"] as? [String: Any]
        #expect((inspectSource?["description"] as? String)?.contains("search result") == true)

        let show = detached.first { $0.name == "show_source_image" }
        #expect(show?.description.contains("need not be attached") == true)

        let message = ReviewSessionManager.sourceNotInLibraryMessage("abc")
        #expect(message.contains("abc is not a source in this library"))
        #expect(message.contains("search_sources_semantic"))
        #expect(message.contains("need not be attached"))
    }

    @Test("extract_video_slides is the chat's own tool once sources are attached, and the MCP twin steps aside")
    @MainActor
    func extractVideoSlidesIsNativeWithAttachedSources() {
        let mcpTwin = ReviewSessionManager.AppToolDefinition(
            name: "extract_video_slides",
            description: "MCP: Capture a library video's slide frames.",
            inputSchemaJSON: "{\"type\":\"object\"}"
        )
        // With a source attached the chat defines the tool itself: it resolves
        // the id against the attached pool and returns the deck listing. The MCP
        // definition of the same name is dropped, because two tools sharing a
        // name is a request the providers refuse.
        let attached = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true, appTools: [mcpTwin], hasSynthesisContext: false
        )
        let attachedExtract = attached.filter { $0.name == "extract_video_slides" }
        #expect(attachedExtract.count == 1)
        #expect(attachedExtract.first?.description.contains("Show slides") == true)
        #expect(attachedExtract.first?.description.contains("show_source_image") == true)
        #expect((attachedExtract.first?.inputSchema["required"] as? [String]) == ["source_id"])
        // Without attached sources there is nothing for the chat's version to
        // capture, so the MCP tool is the one on offer — still exactly once.
        let detached = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [mcpTwin], hasSynthesisContext: false
        )
        let detachedExtract = detached.filter { $0.name == "extract_video_slides" }
        #expect(detachedExtract.count == 1)
        #expect(detachedExtract.first?.description.hasPrefix("MCP:") == true)
    }

    @Test("Native tool specs cover retrieval, synthesis, and app tools")
    @MainActor
    func nativeToolSpecsCoverAllSurfaces() {
        let specs = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            hasSynthesisContext: true
        )

        let names = specs.map(\.name)
        #expect(names.contains("retrieve_sources"))
        #expect(names.contains("inspect_paper_figure"))
        #expect(names.contains("show_source_image"))
        #expect(names.contains("fetch_web_page"))
        #expect(!names.contains("request_web_search"))

        let showImage = specs.first { $0.name == "show_source_image" }
        let imageProperties = showImage?.inputSchema["properties"] as? [String: Any]
        #expect(imageProperties?["query"] != nil)
        #expect(imageProperties?["page"] != nil)
        #expect(imageProperties?["slide"] != nil)
        // Any moment of a video, not only its captured slides, and a crop in on it.
        #expect(imageProperties?["at"] != nil)
        #expect(imageProperties?["crop"] != nil)
        #expect((showImage?.inputSchema["required"] as? [String]) == ["source_id"])

        let generateImage = specs.first { $0.name == "generate_image" }
        let generateProperties = generateImage?.inputSchema["properties"] as? [String: Any]
        #expect(generateProperties?["prompt"] != nil)
        #expect(generateProperties?["title"] != nil, "a new picture is named, not captioned by its prompt")
        #expect((generateProperties?["shape"] as? [String: Any])?["enum"] as? [String] == ["square", "landscape", "portrait"])
        #expect((generateProperties?["quality"] as? [String: Any])?["enum"] as? [String] == ["low", "medium", "high"])
        #expect((generateImage?.inputSchema["required"] as? [String]) == ["prompt"])
        #expect(generateImage?.description.contains("show_source_image") == true)
        let listImages = specs.first { $0.name == "list_generated_images" }
        #expect(listImages != nil)
        #expect((listImages?.inputSchema["properties"] as? [String: Any])?["query"] != nil)
        #expect(listImages?.description.contains("generate_image") == true)
        #expect(generateProperties?["revises"] != nil, "a change to a drawn picture is its next version")
        // The agent chat gets every MCP tool not excluded; the MCP image tools
        // would put a second generate_image in the request beside the chat's own.
        #expect(ReviewSessionManager.chatExcludedToolNames.isSuperset(of: MCPDataStore.imageToolNames))
        #expect(names.contains("add_to_synthesis"))
        #expect(names.contains("replace_synthesis"))
        #expect(names.contains("list_sources"))

        let retrieval = specs.first { $0.name == "retrieve_sources" }
        let properties = retrieval?.inputSchema["properties"] as? [String: Any]
        #expect(properties?["cursor"] != nil)
        #expect(retrieval?.description.contains("continuation cursor") == true)
    }

    @Test("Deep Research receives provider web search directly, without an app shim")
    @MainActor
    func deepResearchToolSpecsOmitWebShim() {
        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: [],
            hasSynthesisContext: false,
            mode: .deepResearch,
            webSearch: .native
        ).map(\.name)

        #expect(!names.contains("request_web_search"))
    }

    @Test("request_web_search is offered only where the route's engine searches unconditionally")
    @MainActor
    func webSearchShimFollowsRouteAccess() {
        func specs(_ access: ReviewSessionManager.WebSearchAccess) -> [AIToolSpec] {
            ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: false,
                appTools: [],
                hasSynthesisContext: false,
                webSearch: access
            )
        }

        #expect(!specs(.native).map(\.name).contains("request_web_search"))
        #expect(!specs(.unavailable).map(\.name).contains("request_web_search"))

        let shim = specs(.onRequest).first { $0.name == "request_web_search" }
        #expect(shim != nil)
        #expect((shim?.inputSchema["required"] as? [String]) == ["query"])
        #expect(shim?.description.contains("targeted library lookup") == true)
    }

    @Test("Study prompt kinds carry only the scoped app-tool surface")
    @MainActor
    func studyModesScopeAppTools() {
        let appTools: [ReviewSessionManager.AppToolDefinition] = [
            .init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "get_source_content", description: "Read a source", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "import_paper_from_url", description: "Import a paper", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "delete_source", description: "Delete a source", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "end_review_session", description: "End a review", inputSchemaJSON: "{\"type\":\"object\"}"),
        ]

        for mode in [
            ReviewSessionManager.InitialPromptMode.review,
            .summarize,
            .shallowRead,
            .deepRead,
        ] {
            let names = ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: true,
                appTools: appTools,
                hasSynthesisContext: true,
                mode: mode
            ).map(\.name)

            // Reading the attached sources stays available in every mode.
            #expect(names.contains("retrieve_sources"))
            #expect(names.contains("list_sources"))
            #expect(names.contains("get_source_content"))
            // A paper the chat brings up can be added on request.
            #expect(names.contains("import_paper_from_url"))
            // Library administration and duplicate review recording do not.
            #expect(!names.contains("delete_source"))
            #expect(!names.contains("end_review_session"))
        }

        // The agent surface still gets everything.
        let agentNames = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true,
            appTools: appTools,
            hasSynthesisContext: true,
            mode: .assistant
        ).map(\.name)
        #expect(agentNames.contains("delete_source"))
        #expect(agentNames.contains("end_review_session"))
    }

    @Test("Notebook chat reaches the whole library while staying pinned to its own Notebook")
    @MainActor
    func notebookChatScopesSourceTools() {
        let appTools: [ReviewSessionManager.AppToolDefinition] = [
            .init(name: "get_app_context", description: "Get context", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "list_sources", description: "List all sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "get_source_content", description: "Read source", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "search_sources_semantic", description: "Search sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "get_notebook_context", description: "Read notebook", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "add_notebook_sources", description: "Add notebook sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "list_notebook_sources", description: "List notebook sources", inputSchemaJSON: "{\"type\":\"object\"}"),
        ]

        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true,
            appTools: appTools,
            hasSynthesisContext: true,
            notebookScopeID: "notebook-1"
        ).map(\.name)

        #expect(!names.contains("get_app_context"))
        #expect(names.contains("list_sources"))
        #expect(names.contains("get_source_content"))
        #expect(names.contains("search_sources_semantic"))
        #expect(names.contains("get_notebook_context"))
        #expect(names.contains("add_notebook_sources"))
        #expect(names.contains("list_notebook_sources"))

        // A chat that lives outside every Notebook has no Notebook context at all.
        // The sidebar's highlighted Notebook must not become one by way of
        // get_app_context, in either the study surface or the agent surface.
        for mode in [ReviewSessionManager.InitialPromptMode.review, .assistant] {
            let unscopedNames = ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: true,
                appTools: appTools,
                hasSynthesisContext: false,
                mode: mode,
                notebookScopeID: nil
            ).map(\.name)
            #expect(!unscopedNames.contains("get_app_context"))
            #expect(unscopedNames.contains("search_sources_semantic"))
        }

        // An unscoped search stays library-wide: the Notebook pool is already
        // attached, so a search exists to find what is not in hand yet.
        let defaultSearch = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "search_sources_semantic",
            arguments: ["query": "mitochondria"],
            notebookScopeID: "notebook-1"
        )
        #expect(defaultSearch["notebook_id"] == nil)
        #expect(defaultSearch["exclude_notebook_id"] == nil)

        // A deliberately scoped search is aimed at this Notebook, never another.
        let insideSearch = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "search_sources_semantic",
            arguments: ["query": "mitochondria", "notebook_id": "wrong-notebook"],
            notebookScopeID: "notebook-1"
        )
        #expect(insideSearch["notebook_id"] as? String == "notebook-1")

        let outsideSearch = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "search_sources_semantic",
            arguments: ["query": "mitochondria", "exclude_notebook_id": "wrong-notebook"],
            notebookScopeID: "notebook-1"
        )
        #expect(outsideSearch["notebook_id"] == nil)
        #expect(outsideSearch["exclude_notebook_id"] as? String == "notebook-1")

        let addSources = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "add_notebook_sources",
            arguments: [
                "notebook_id": "wrong-notebook",
                "source_ids": ["source-2"],
            ],
            notebookScopeID: "notebook-1"
        )
        #expect(addSources["notebook_id"] as? String == "notebook-1")

        // The notebook's chat checkboxes are this Notebook's, never another's.
        let selection = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "set_notebook_source_selection",
            arguments: [
                "notebook_id": "wrong-notebook",
                "mode": "exclude",
                "source_ids": ["source-2"],
            ],
            notebookScopeID: "notebook-1"
        )
        #expect(selection["notebook_id"] as? String == "notebook-1")

        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: true,
            appTools: appTools,
            notebookScopeID: "notebook-1"
        )
        #expect(prompt.contains("attached source catalog is the working set"))
        #expect(prompt.contains("The Notebook is a focus, not a wall"))
        #expect(prompt.contains("get_source_content reads any source in it"))
        #expect(prompt.contains("nothing to ask permission for"))
        #expect(prompt.contains("dated meeting recording, transcript, notes"))
        #expect(prompt.contains("just look it up and read it"))
        #expect(prompt.contains("does not add it to the Notebook"))
        #expect(prompt.contains("marks the rest in_chat false"))
        #expect(prompt.contains("only when the learner asks"))
        #expect(!prompt.contains("Notebook source boundary"))
        #expect(!prompt.contains("automatically restricted to this Notebook"))
    }

    @Test("Notebook chat reads a library source that is not in the Notebook")
    @MainActor
    func notebookChatReadsSourceOutsideItsNotebook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookChatLibraryReach_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let source = StudioArticle(
            url: "https://example.com/journal-club-recording",
            title: "Journal Club — Somatic Mutations",
            sourceType: .article,
            id: "journal-club-recording"
        )
        try await storage.saveSource(source)
        let notebook = try await storage.createCompanionGoal(
            title: "Thyroid Autoimmunity",
            topic: "thyroid autoimmunity",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        // The meeting recording is nowhere near this Notebook's source pool, and
        // no outside search preceded the read. It is still the learner's own
        // library, so the read reaches the tool instead of being refused.
        let result = await ReviewSessionManager.notebookChatAppToolResultForTesting(
            storage: storage,
            notebookScopeID: notebook.id,
            toolName: "get_source_content",
            arguments: ["source_id": source.id]
        )
        #expect(!result.isError)
        #expect(result.text == "the tool ran")
    }

    @Test("Flattened turns merge roles and summarize tool traffic")
    @MainActor
    func flattenedTurnsMergeRoles() {
        let call = AIToolCallRequest(id: "c1", name: "list_sources", argumentsJSON: "{}")
        let messages = ReviewSessionManager.flattenedProviderMessagesForTesting(from: [
            .user("Hi"),
            .assistant(text: "Checking.", toolCalls: [call]),
            .toolResults([AIToolResultPayload(callID: "c1", toolName: "list_sources", text: "3 sources", isError: false)]),
            .user("Thanks"),
        ])

        #expect(messages.map(\.role) == ["user", "assistant", "user"])
        #expect(messages[1].content.contains("[Called list_sources]"))
        #expect(messages[2].content.contains("3 sources"))
    }

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
        #expect(claudeTail.map { $0["text"] as? String } == ["volatile tail"])
        #expect(claudeTail[0]["cache_control"] == nil)
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
        #expect(geminiVolatile.count == 1)
        #expect(geminiVolatile[0]["text"] as? String == "volatile tail")
        #expect(geminiVolatile[0]["cache_control"] == nil)
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
            #expect(secondTail.first?["text"] as? String == "clock 10:01", "\(model)")
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
        #expect(firstTail[0]["text"] as? String == "\n\nVOLATILE-TURN-A")
        #expect(firstTail[0]["cache_control"] == nil)

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
        #expect(tail[0]["text"] as? String == "\n\nVOLATILE-B")
        #expect(tail[0]["cache_control"] == nil)
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
        #expect(tail.map { $0["text"] as? String } == ["TAIL"])
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
        #expect(dynamicBlocks[0]["text"] as? String == "CHANGING-HISTORY-DIGEST")
        #expect(dynamicBlocks[0]["cache_control"] == nil)
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

    // MARK: - Queued-message exchange pairing

    @Test("Queued messages pair with their own evaluations, oldest first")
    func queuedMessagesPairOldestFirst() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "Pairing", sourceIDs: [])

        // Tutor asks; learner answers; a second message is queued mid-turn.
        try store.addReviewPrompt(sessionID: "s1", question: "Q1", sourceRefs: [])
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message one", sourceRefs: [])
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message two", sourceRefs: [])

        // Turn 1 completes: its evaluation must land on the row holding message
        // one — and must not overwrite that eagerly-persisted answer even though
        // the caller passes the latest user message.
        let firstSequence = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message two", evaluation: "eval one",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        // Follow-up turn completes: pairs with message two.
        let secondSequence = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message two", evaluation: "eval two",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        #expect(firstSequence == 1)
        #expect(secondSequence == 2)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.count == 2)
        #expect(exchanges[0].userAnswer == "message one")
        #expect(exchanges[0].evaluation == "eval one")
        #expect(exchanges[1].userAnswer == "message two")
        #expect(exchanges[1].evaluation == "eval two")
    }

    @Test("A reply stopped before it began closes its row, so the next reply pairs with its own message")
    func emptyStopClosesPendingRow() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "Steering", sourceIDs: [])

        // Message one's turn is cut short by Send now on message two before it
        // produced any text; message two is admitted behind it.
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message one", sourceRefs: [])
        let closed = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message one", evaluation: "",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message two", sourceRefs: [])

        // Message two's reply lands on message two, not on the stopped row.
        let answered = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message two", evaluation: "the short answer",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        #expect(closed == 1)
        #expect(answered == 2)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.count == 2)
        #expect(exchanges[0].userAnswer == "message one")
        #expect(exchanges[0].evaluation == "")
        #expect(exchanges[1].userAnswer == "message two")
        #expect(exchanges[1].evaluation == "the short answer")
    }

    @Test("Evaluations never land on historical rows before the last evaluated exchange")
    func evaluationsSkipHistoricalRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "History", sourceIDs: [])

        // An imported transcript row with an answer but no evaluation, followed
        // by a completed exchange.
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "old imported note", sourceRefs: [])
        try store.addReviewExchange(
            sessionID: "s1", question: "Q", answer: "A", evaluation: "E",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        // With nothing pending after the evaluated row, the historical row must
        // stay untouched and the caller falls back to a fresh exchange.
        let sequence = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "new answer", evaluation: "new eval",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        #expect(sequence == nil)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges[0].userAnswer == "old imported note")
        #expect(exchanges[0].evaluation == nil)
    }

    @Test("A reply given a row answers that row, and only while it has no reply")
    func namedRowTakesTheReply() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "Pairing", sourceIDs: [])
        let stopped = try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message one", sourceRefs: [])
        let asked = try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message two", sourceRefs: [])
        #expect(stopped == 1)
        #expect(asked == 2)

        // Row one is older and open, but the reply names row two.
        let answered = try store.answerPendingReviewExchange(
            sessionID: "s1", sequence: asked, answer: "message two", evaluation: "reply to two",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        // A row that has its reply is not answered again.
        let again = try store.answerPendingReviewExchange(
            sessionID: "s1", sequence: asked, answer: "message two", evaluation: "a second reply",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        #expect(answered == 2)
        #expect(again == nil)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.map(\.userAnswer) == ["message one", "message two"])
        #expect(exchanges.map(\.evaluation) == [nil, "reply to two"])
    }

    /// The chat as its rows keep it: each learner message, and the reply
    /// saved on its row.
    private static func storedPairs(_ storage: StorageService, sessionID: String) async throws -> [(answer: String?, reply: String?)] {
        try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map { (answer: $0.userAnswer, reply: $0.evaluation) }
    }

    private static let pairingConfig = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "z-ai/glm-5.3-flash")

    /// A quiz answer whose turn ran to its reply.
    @MainActor
    private static func answered(_ answer: String, reply: String, in manager: ReviewSessionManager, config: AITaskConfig) async throws {
        await manager.saveLearnerMessageForTesting(answer)
        manager.beginTurnForTesting()
        try await manager.finishTurnForTesting(reply: reply, config: config)
    }

    /// A quiz answer whose grade was cut short: the learner pressed ↑ on a
    /// message queued under it, and the turn ended having said nothing.
    @MainActor
    private static func cutShort(_ answer: String, in manager: ReviewSessionManager, config: AITaskConfig) async {
        await manager.saveLearnerMessageForTesting(answer)
        manager.beginTurnForTesting()
        await manager.stopTurnBeforeReplyForTesting(streamedRowShown: false, config: config)
    }

    @Test("A quiz grade cut short by Send now leaves its answer unanswered, and every later answer keeps its own reply")
    @MainActor
    func quizReplyPairsWithItsOwnAnswerAfterCutShortGrades() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuizReplyPairing_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let sessionID = CourseQuizSitting.sessionID(forQuizID: "cq-cristae")
        try await storage.createReviewSession(id: sessionID, topic: "Quiz: Cristae Architecture and State", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        let config = Self.pairingConfig
        await manager.openScriptedReviewForTesting(
            sessionID: sessionID,
            opening: "Quiz: Cristae Architecture and State · 15 questions\n\n**Question 1 of 15 · Recall**\n\nWhich major metabolic pathways named in the lecture occur in the mitochondrial matrix?"
        )

        // The start of the sitting of 2026-09-27, whose third and fifth
        // answers drew no saved reply.
        let q1FollowUp = "You have one pathway. What other major metabolic pathway named in the lecture also occurs there?"
        let q1Grade = "**Partly**\n\nYou missed beta-oxidation.\n\n**Question 2 of 15 · Explain**\n\nWhy is the inner mitochondrial membrane central to ATP production?"
        let sideAnswer = "**Beta-oxidation** breaks fatty acids down into acetyl-CoA.\n\n**Question 2 of 15 · Explain**\n\nWhy is the inner mitochondrial membrane central to ATP production?"
        let q2Grade = "**Right**\n\nThe electron-transport chain sits in the inner membrane.\n\n**Question 3 of 15 · Explain**\n\nWhy should the intermembrane space be treated as a distinct compartment?"
        let q3FollowUp = "**Question 3 · follow-up**\n\nWhat do those molecules do there?"
        let q3Grade = "**Right**\n\nThe space holds its own molecules and gradients.\n\n**Question 4 of 15 · Recall**\n\nWhat distinguishes a mitochondrial contact site?"
        try await Self.answered("tca cycle", reply: q1FollowUp, in: manager, config: config)
        try await Self.answered("not sure", reply: q1Grade, in: manager, config: config)
        await Self.cutShort("not sure", in: manager, config: config)
        try await Self.answered("what is beta oxidation used for btw? just following up on q1", reply: sideAnswer, in: manager, config: config)
        await Self.cutShort("that is where all the oxphos complexes are", in: manager, config: config)
        try await Self.answered("that is where the etc is", reply: q2Grade, in: manager, config: config)
        try await Self.answered("there are also molecules and gradients there", reply: q3FollowUp, in: manager, config: config)
        try await Self.answered("get exported and imported", reply: q3Grade, in: manager, config: config)

        let pairs = try await Self.storedPairs(storage, sessionID: sessionID)
        #expect(pairs.map { $0.answer } == [
            "tca cycle",
            "not sure",
            "not sure",
            "what is beta oxidation used for btw? just following up on q1",
            "that is where all the oxphos complexes are",
            "that is where the etc is",
            "there are also molecules and gradients there",
            "get exported and imported",
        ])
        #expect(pairs.map { $0.reply } == [q1FollowUp, q1Grade, nil, sideAnswer, nil, q2Grade, q3FollowUp, q3Grade])
        // The row times follow the conversation, as they do when each reply
        // is kept on the message it answers.
        let times = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .compactMap { $0.answeredAt }
        #expect(times.count == 8)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A chat turn stopped or failed before it replied never takes the next reply")
    @MainActor
    func turnWithoutReplyKeepsItsRowToItself() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatReplyPairing_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Cristae", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        let config = Self.pairingConfig

        // Stopped while it searched: the empty row is closed.
        await manager.saveLearnerMessageForTesting("find the cristae junction paper")
        manager.beginTurnForTesting()
        await manager.stopTurnBeforeReplyForTesting(streamedRowShown: true, config: config)
        // Stopped while a tool ran: the streamed row was already gone.
        await manager.saveLearnerMessageForTesting("the 2020 one")
        manager.beginTurnForTesting()
        await manager.stopTurnBeforeReplyForTesting(streamedRowShown: false, config: config)
        // Failed, and the learner sent something new instead of Retry.
        await manager.saveLearnerMessageForTesting("what is a crista junction?")
        manager.beginTurnForTesting()
        await manager.saveLearnerMessageForTesting("in one sentence")
        manager.beginTurnForTesting()
        let reply = "The narrow neck joining a crista to the inner boundary membrane."
        try await manager.finishTurnForTesting(reply: reply, config: config)

        let pairs = try await Self.storedPairs(storage, sessionID: "chat")
        #expect(pairs.map { $0.answer } == ["find the cristae junction paper", "the 2020 one", "what is a crista junction?", "in one sentence"])
        #expect(pairs.map { $0.reply } == ["", nil, nil, reply])
    }

    @Test("Retry answers the failed message's own row, and a message sent while a turn runs waits for its own reply")
    @MainActor
    func retryAndMidTurnMessageKeepTheirRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatRetryPairing_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Cristae", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        let config = Self.pairingConfig

        // A turn fails; Retry runs it again on the same message.
        await manager.saveLearnerMessageForTesting("one")
        manager.beginTurnForTesting()
        manager.beginTurnForTesting()
        try await manager.finishTurnForTesting(reply: "reply to one", config: config)
        // A message saved while the turn before it is still running.
        await manager.saveLearnerMessageForTesting("two")
        manager.beginTurnForTesting()
        await manager.saveLearnerMessageForTesting("three")
        try await manager.finishTurnForTesting(reply: "reply to two", config: config)
        manager.beginTurnForTesting()
        try await manager.finishTurnForTesting(reply: "reply to three", config: config)

        let pairs = try await Self.storedPairs(storage, sessionID: "chat")
        #expect(pairs.map { $0.answer } == ["one", "two", "three"])
        #expect(pairs.map { $0.reply } == ["reply to one", "reply to two", "reply to three"])
    }

    // MARK: - Streaming display

    @Test("Trailing partial tool-call tag fragments never flicker into the bubble")
    @MainActor
    func partialToolCallTagIsStrippedDuringStreaming() {
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag("Let me check. <flm_tool_c")
            == "Let me check. ")
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag("Almost done <")
            == "Almost done ")
        // Legitimate text is left alone.
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag("a < b")
            == "a < b")
        // A complete tag is not this helper's job (removeToolCallBlocks owns it).
        let complete = "Check. <flm_tool_call>"
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag(complete) == complete)
    }

    @Test("Leaked tool-name lines are dropped from lead-in text before a tool call")
    @MainActor
    func leakedToolNameLinesAreStripped() {
        // The bare tool name alone (the screenshot case) disappears entirely.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "start_review_session", toolNames: ["start_review_session"]) == "")
        // Decorated variants (backticks, colon) are still just debris.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "`start_review_session`:", toolNames: ["start_review_session"]) == "")
        // Real prose around the call survives, including prose mentioning the tool.
        let prose = "Let me start a review with start_review_session."
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            prose, toolNames: ["start_review_session"]) == prose)
        // Mixed: the debris line goes, the prose line stays.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "start_review_session\nStarting your quiz now.",
            toolNames: ["start_review_session"]) == "Starting your quiz now.")
        // No tool calls → nothing is touched.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "start_review_session", toolNames: []) == "start_review_session")
        // Blank lines carry markdown paragraph breaks and must survive.
        let paragraphs = "First thought.\n\nSecond thought."
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            paragraphs, toolNames: ["start_review_session"]) == paragraphs)
    }

    @Test("Native tool results are shortened only when the actual model window is exceeded")
    @MainActor
    func nativeToolResultsTruncateInPlace() {
        let bigText = String(repeating: "y", count: 40_000)
        let turns: [AIChatTurn] = [
            .user("go"),
            .assistant(text: "", toolCalls: [AIToolCallRequest(id: "c1", name: "search_sources_semantic", argumentsJSON: "{}")]),
            .toolResults([AIToolResultPayload(callID: "c1", toolName: "search_sources_semantic", text: bigText, isError: false)]),
        ]
        // A tiny model window forces trimming.
        let config = AITaskConfig(provider: .cerebras, apiKey: "k", model: "llama3.1-8b")

        let trimmed = ReviewSessionManager.trimmedNativeToolResultTurnsForTesting(
            turns,
            systemPrompt: "SYSTEM",
            config: config
        )

        guard case .toolResults(let results) = trimmed[2] else {
            Issue.record("Tool results turn was dropped — pairing must be preserved")
            return
        }
        #expect(results.count == 1)
        #expect(results[0].callID == "c1")
        #expect(results[0].text.count < bigText.count)
        #expect(results[0].text.lowercased().contains("shortened"))
    }

    @Test("The newest complete paper is fed verbatim even when other input must shrink")
    @MainActor
    func newestFullPaperIsProtectedFromOverflowTrimming() {
        let paper = "# Complete paper\n\n" + String(repeating: "source evidence. ", count: 3_000)
        let olderSearch = String(repeating: "older search result ", count: 2_000)
        let turns: [AIChatTurn] = [
            .user("Read the paper."),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "search-call", name: "search_sources_semantic", argumentsJSON: "{}")
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "search-call",
                    toolName: "search_sources_semantic",
                    text: olderSearch,
                    isError: false
                )
            ]),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "paper-call", name: "get_source_content", argumentsJSON: "{}")
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "paper-call",
                    toolName: "get_source_content",
                    text: paper,
                    isError: false
                )
            ]),
        ]
        let config = AITaskConfig(provider: .cerebras, apiKey: "k", model: "llama3.1-8b")

        let trimmed = ReviewSessionManager.trimmedNativeToolResultTurnsForTesting(
            turns,
            systemPrompt: "SYSTEM",
            config: config
        )

        guard case .toolResults(let olderResults) = trimmed[2],
              case .toolResults(let paperResults) = trimmed[4] else {
            Issue.record("Tool result pairing was not preserved")
            return
        }
        #expect(olderResults[0].text.count < olderSearch.count)
        #expect(paperResults[0].text == paper)
    }

    @Test("A complete paper tool result stays verbatim when it fits the model window")
    @MainActor
    func fullPaperToolResultIsNotPrematurelyTruncated() {
        let paper = "# Gupta paper\n\n" + String(repeating: "complete source evidence. ", count: 8_000)
        let turns: [AIChatTurn] = [
            .user("Open the Gupta paper and answer from it."),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "paper-call", name: "get_source_content", argumentsJSON: "{\"source_id\":\"gupta\"}")
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "paper-call",
                    toolName: "get_source_content",
                    text: paper,
                    isError: false
                )
            ]),
        ]
        let config = AITaskConfig(provider: .openai, apiKey: "k", model: "gpt-5.4")

        let kept = ReviewSessionManager.trimmedNativeToolResultTurnsForTesting(
            turns,
            systemPrompt: String(repeating: "instruction ", count: 4_000),
            toolCharacters: 40_000,
            config: config
        )

        guard case .toolResults(let results) = kept[2] else {
            Issue.record("Tool results turn was dropped")
            return
        }
        #expect(results.count == 1)
        #expect(results[0].text == paper)
        #expect(!results[0].text.lowercased().contains("truncat"))
        #expect(!results[0].text.lowercased().contains("shortened"))
    }

    // MARK: - Context breakdown (composer gauge)

    @Test("Context breakdown splits instructions, sources, tools, and conversation")
    @MainActor
    func contextBreakdownSplitsComponents() {
        let sourceText = String(repeating: "s", count: 8_000)
        let instructions = String(repeating: "i", count: 4_000)
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: instructions + sourceText,
            volatileSystem: String(repeating: "v", count: 400),
            sourceContext: sourceText,
            perSourceShares: [],
            conversationCharacters: 2_000,
            toolCharacters: 1_200,
            config: config
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        // 4 characters per token, and the source text must be charged to
        // sources rather than double-counted into instructions.
        #expect(breakdown.instructionTokens == 1_000)
        #expect(breakdown.sourceTokens == 2_000)
        #expect(breakdown.toolTokens == 300)
        #expect(breakdown.conversationTokens == 500)
        #expect(breakdown.volatileTokens == 100)
        #expect(breakdown.usedTokens == 3_900)
        #expect(breakdown.contextWindowTokens == 1_000_000)
        #expect(breakdown.freeTokens == 1_000_000 - 3_900)
    }

    @Test("Context breakdown never reports a negative or over-full window")
    @MainActor
    func contextBreakdownClampsToWindow() {
        // A tiny window plus an oversized conversation must clamp at 100% used
        // and zero free rather than going negative.
        let config = AITaskConfig(provider: .cerebras, apiKey: "k", model: "llama3.1-8b")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: "SYSTEM",
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 4_000_000,
            toolCharacters: 0,
            config: config
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        #expect(breakdown.sourceTokens == 0)
        #expect(breakdown.freeTokens == 0)
        #expect(breakdown.usedFraction == 1.0)
    }

    @Test("The source catalog is charged to sources, not to instructions")
    @MainActor
    func contextBreakdownChargesCatalogToSources() {
        // A large Notebook pool produces a large catalog. Counting it as
        // instructions would render as an enormous system prompt beside an
        // empty "Attached sources" row — the opposite of what is happening.
        let manifest = String(repeating: "m", count: 6_000)
        let instructions = String(repeating: "i", count: 4_000)
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: instructions + manifest,
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config,
            sourceManifest: manifest
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        #expect(breakdown.sourceTokens == 1_500)
        #expect(breakdown.instructionTokens == 1_000)
    }

    @Test("Per-source shares are captured for each attached source")
    @MainActor
    func perSourceSharesArePublished() {
        let shares = [
            ReviewSessionManager.ChatContextBreakdown.SourceShare(id: "a", title: "Alpha", characters: 480),
            ReviewSessionManager.ChatContextBreakdown.SourceShare(id: "b", title: "Beta", characters: 320),
        ]
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: "SYSTEM",
            volatileSystem: "",
            sourceContext: String(repeating: "s", count: 800),
            perSourceShares: shares,
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config
        )

        #expect(breakdown?.perSource.map(\.id) == ["a", "b"])
        #expect(breakdown?.perSource.map(\.title) == ["Alpha", "Beta"])
        #expect(breakdown?.perSource.reduce(0) { $0 + breakdown!.tokens($1.characters) } == 200)
    }

    @Test("Provider-reported prompt tokens replace the char estimate")
    @MainActor
    func contextBreakdownCalibratesFromReportedUsage() {
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")
        // 8k characters total: the flat /4 guess says 2,000 tokens, but the
        // provider bills 2,500 across fresh input, cache reads, and writes.
        let usage = usageEvent(
            provider: config.provider.shortName,
            model: config.model,
            input: 500,
            cached: 1_500,
            cacheCreation: 500
        )

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: String(repeating: "i", count: 4_000),
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 4_000,
            toolCharacters: 0,
            config: config,
            usage: usage
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        #expect(breakdown.isCalibrated)
        #expect(breakdown.usedTokens == 2_500)
        #expect(breakdown.charactersPerToken == 3.2)
        // Components rescale to the measured ratio rather than staying at /4.
        #expect(breakdown.instructionTokens == 1_250)
        #expect(breakdown.conversationTokens == 1_250)
    }

    @Test("Usage recorded before the request was assembled is ignored")
    @MainActor
    func contextBreakdownIgnoresStaleUsage() {
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")
        // A previous round's much smaller request must not be reported as this
        // one's total just because it is the most recent event on record.
        let stale = usageEvent(
            provider: config.provider.shortName,
            model: config.model,
            input: 40,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: String(repeating: "i", count: 8_000),
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config,
            usage: stale
        )

        #expect(breakdown?.isCalibrated == false)
        #expect(breakdown?.usedTokens == 2_000)
    }

    @Test("Usage from another model does not calibrate this request")
    @MainActor
    func contextBreakdownIgnoresOtherModelUsage() {
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")
        let other = usageEvent(provider: config.provider.shortName, model: "claude-opus-4-8", input: 9_000)

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: String(repeating: "i", count: 8_000),
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config,
            usage: other
        )

        #expect(breakdown?.isCalibrated == false)
        #expect(breakdown?.usedTokens == 2_000)
    }

    @Test("Prompt totals normalize Anthropic and OpenAI cache conventions")
    func promptTokensNormalizesCacheReporting() {
        // Anthropic reports input_tokens exclusive of cache reads and writes.
        let anthropic = usageEvent(
            provider: AIProvider.anthropic.shortName,
            model: "claude-sonnet-5",
            input: 100,
            cached: 900,
            cacheCreation: 200
        )
        #expect(ReviewSessionManager.promptTokens(of: anthropic) == 1_200)

        // OpenAI-style providers already fold cached reads into prompt_tokens,
        // so adding them again would double-count.
        let openAI = usageEvent(
            provider: AIProvider.openai.shortName,
            model: "gpt-5",
            input: 1_000,
            cached: 900
        )
        #expect(ReviewSessionManager.promptTokens(of: openAI) == 1_000)
    }

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

    private func usageEvent(
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

        // Citations add the Sources footer: one card per distinct source, so
        // the same number cited twice is one card.
        let cited = ChatMarkdownHeightEstimate.estimatedHeight(
            markdown: paragraph + " [1] and again [1], then [2].",
            width: width,
            fontSize: size
        )
        let citedOnce = ChatMarkdownHeightEstimate.estimatedHeight(
            markdown: paragraph + " [1].",
            width: width,
            fontSize: size
        )
        #expect(citedOnce > short)
        #expect(cited > citedOnce)
        #expect(cited - citedOnce < (citedOnce - short))
    }

}

// MARK: - Chat tool surface

/// Which app tools a chat can call is decided by two static sets. A study chat
/// — the chat on a Notebook or on a paper — is scoped hard, so anything a
/// learner says out loud there has to be listed by name; Slack was not, and a
/// Notebook chat asked about a PDF posted that week searched the library nine
/// times and never read the channel.
@Suite("Chat tool surface")
struct ChatToolSurfaceTests {
    @Test("A study chat can read Slack live and file a posted PDF onto its paper")
    func studyChatsReachSlack() {
        let study = ReviewSessionManager.studySurfaceToolNames
        #expect(study.contains("list_slack_channels"))
        #expect(study.contains("read_slack_channel"))
        #expect(study.contains("read_slack_thread"))
        #expect(study.contains("search_slack_messages"))
        #expect(study.contains("attach_pdf_to_paper"))
        #expect(study.contains("import_paper_from_url"))
    }

    @Test("A study chat asked to schedule its papers can put them on the Mac's Calendar")
    func studyChatsReachTheCalendar() {
        let study = ReviewSessionManager.studySurfaceToolNames
        // create_calendar_event is also what turns on the calendar guidance.
        #expect(study.isSuperset(of: [
            "get_calendar_events", "create_calendar_event", "update_calendar_event",
            "delete_calendar_event", "list_goals", "get_goal"
        ]))
        #expect(study.isDisjoint(with: ["get_day_plan", "add_time_block", "revise_day_plan"]))
    }

    @Test("Every chat can put what it names on the learner's screen")
    func everyChatCanOpenThings() {
        // 2026-10-11: asked to open a notebook, a chat said it had and nothing
        // moved. A study chat had no tool that opens anything.
        #expect(ReviewSessionManager.studySurfaceToolNames.isSuperset(of: ["open_in_app", "list_notebooks"]))
        #expect(ReviewSessionManager.chatExcludedToolNames.isDisjoint(with: ["open_in_app", "list_notebooks"]))
    }

    @Test("A chat may say it did something only when a tool did it, and opening is a tool")
    @MainActor
    func chatClaimsOnlyWhatAToolDid() {
        let openInApp = ReviewSessionManager.AppToolDefinition(
            name: "open_in_app", description: "Show one of the learner's things", inputSchemaJSON: "{\"type\":\"object\"}"
        )
        let listSources = ReviewSessionManager.AppToolDefinition(
            name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"
        )
        // The chat on a paper, a study kind: open_in_app reaches it now.
        let study = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Ageing",
            hasAttachedSource: true,
            appTools: [openInApp, listSources],
            mode: .deepRead
        )
        #expect(study.contains("only when a tool call in this turn did it"))
        #expect(study.contains("call open_in_app with its id"))

        let agent = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Ageing",
            hasAttachedSource: false,
            appTools: [openInApp, listSources]
        )
        #expect(agent.contains("call open_in_app with its id"))

        // Without the tool the rule stands, and names no tool the chat lacks.
        let withoutOpening = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Ageing",
            hasAttachedSource: false,
            appTools: [listSources]
        )
        #expect(withoutOpening.contains("only when a tool call in this turn did it"))
        #expect(!withoutOpening.contains("open_in_app"))
    }

    @Test("Nothing the study surface lists is excluded from the agent chat")
    func studySurfaceIsNeverExcluded() {
        let overlap = ReviewSessionManager.studySurfaceToolNames
            .intersection(ReviewSessionManager.chatExcludedToolNames)
        #expect(overlap.isEmpty, "\(overlap.sorted())")
    }

    /// A catalog the size of the real one: the core tools plus filler whose
    /// schemas push the surface past the deferral budget.
    static let bigCatalog: [ReviewSessionManager.AppToolDefinition] = {
        let padding = String(repeating: "x", count: 900)
        let core = ["search_sources_semantic", "open_in_app", "list_notebooks"].map {
            ReviewSessionManager.AppToolDefinition(name: $0, description: "Core \($0)", inputSchemaJSON: "{\"type\":\"object\"}")
        }
        let filler = (0..<60).map { index in
            ReviewSessionManager.AppToolDefinition(
                name: "rare_tool_\(index)",
                description: "Rarely used action \(index). \(padding)",
                inputSchemaJSON: "{\"type\":\"object\"}"
            )
        }
        let audio = ReviewSessionManager.AppToolDefinition(
            name: "generate_audio_overview",
            description: "Make a podcast-style audio overview of sources. \(padding)",
            inputSchemaJSON: "{\"type\":\"object\",\"properties\":{\"source_ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}"
        )
        return core + filler + [audio]
    }()

    @Test("A chat over the full catalog sends the core tools whole and names the rest in load_app_tools")
    @MainActor
    func bigCatalogDefersTheLongTail() throws {
        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: Self.bigCatalog,
            hasSynthesisContext: false,
            mode: .assistant
        ).map(\.name)
        #expect(names.contains("search_sources_semantic"))
        #expect(names.contains("open_in_app"))
        #expect(!names.contains("rare_tool_0"))
        #expect(!names.contains("generate_audio_overview"))
        #expect(names.filter { $0 == "load_app_tools" }.count == 1)

        let loader = try #require(ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: Self.bigCatalog,
            hasSynthesisContext: false,
            mode: .assistant
        ).first { $0.name == "load_app_tools" })
        #expect(loader.description.contains("generate_audio_overview"))
        #expect(loader.description.contains("rare_tool_59"))
        #expect(!loader.description.contains("open_in_app"))
    }

    @Test("A small tool surface is sent whole, with no loader")
    @MainActor
    func smallSurfaceSendsEverything() {
        let small = Self.bigCatalog.prefix(5).map {
            ReviewSessionManager.AppToolDefinition(name: $0.name, description: "Short", inputSchemaJSON: $0.inputSchemaJSON)
        }
        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: Array(small),
            hasSynthesisContext: false,
            mode: .assistant
        ).map(\.name)
        #expect(names.contains("rare_tool_1"))
        #expect(!names.contains("load_app_tools"))
    }

    @Test("A loaded tool joins the request after the core tools and stays for the chat")
    @MainActor
    func loadingAddsTheToolForLaterRounds() {
        let (results, specs) = ReviewSessionManager.toolSpecsAfterLoadingForTesting(
            appTools: Self.bigCatalog,
            loads: [
                ["names": ["rare_tool_7", "not_a_tool"]],
                ["query": "audio overview podcast"],
                ["names": ["open_in_app"]],
                ["names": ["still_not_a_tool"]],
            ]
        )
        let names = specs.map(\.name)
        #expect(results[0].isError == false)
        #expect(results[0].text.contains("rare_tool_7"))
        #expect(results[0].text.contains("Not tools here: not_a_tool"))
        #expect(results[1].text.contains("generate_audio_overview"))
        #expect(results[2].isError == false)
        #expect(results[2].text.contains("Already in your tool list"))
        #expect(results[3].isError)
        #expect(names.contains("rare_tool_7"))
        #expect(names.contains("generate_audio_overview"))
        #expect(!names.contains("rare_tool_8"))
        // Loaded tools come after the core ones, so the head of the list
        // the request already carried does not move.
        let core = names.firstIndex(of: "open_in_app") ?? .max
        let loaded = names.firstIndex(of: "rare_tool_7") ?? -1
        #expect(core < loaded)
    }

    @Test("A query finds deferred tools by name first, then by description")
    func loaderQueryRanksNamesFirst() {
        let found = ReviewSessionManager.appTools(
            matching: "audio overview",
            in: Self.bigCatalog,
            limit: 3
        ).map(\.name)
        #expect(found.first == "generate_audio_overview")
        #expect(ReviewSessionManager.appTools(matching: "of", in: Self.bigCatalog, limit: 3).isEmpty)
    }

    @Test("Every core tool is one the agent chat can carry")
    func coreToolsAreNeverExcluded() {
        let overlap = ReviewSessionManager.coreAppToolNames
            .intersection(ReviewSessionManager.chatExcludedToolNames)
        #expect(overlap.isEmpty, "\(overlap.sorted())")
    }

    @Test("A notebook chat carries update_notebook, so renaming one needs no load step")
    func updateNotebookTravelsWithTheCoreTools() {
        #expect(ReviewSessionManager.coreAppToolNames.contains("update_notebook"))
    }
}

// MARK: - Working indicator label

@Suite("Review chat working indicator label")
struct ReviewChatWorkingIndicatorLabelTests {
    @Test func namedWaitReplacesTheGenericPreparingLine() {
        #expect(
            ReviewChatWorkingIndicator.label(for: .preparing, detail: "Downloading PSW 2538")
                == "Downloading PSW 2538"
        )
        #expect(ReviewChatWorkingIndicator.label(for: .preparing, detail: "  ") == "Getting your sources ready")
        #expect(ReviewChatWorkingIndicator.label(for: .preparing, detail: nil) == "Getting your sources ready")
    }

    @Test func otherPhasesIgnoreTheDetail() {
        #expect(ReviewChatWorkingIndicator.label(for: .thinking, detail: "Downloading X") == "Thinking")
        #expect(ReviewChatWorkingIndicator.label(for: .writing, detail: "Downloading X") == "Writing")
        #expect(ReviewChatWorkingIndicator.label(for: .searching, detail: "Downloading X") == "Searching your library")
        #expect(ReviewChatWorkingIndicator.label(for: .planning, detail: "Downloading X") == "Planning today's review")
    }
}

struct ReviewChatWorkingIndicatorReasoningTests {
    @Test func nothingShownMeansNoLine() {
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse("") == nil)
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse(" \n ") == nil)
    }

    @Test func summariesQuoteTheirNewestHeading() {
        let summary = """
        **Recalling the exchanger**

        The paper calls it pending, so I should check NHE6 and NHE9.

        **Checking later identifications**

        LETM1 was proposed as a K+/H+ exchanger
        """
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse(summary) == "Checking later identifications")
    }

    @Test func rawThinkingQuotesTheTailOfItsNewestParagraph() {
        #expect(
            ReviewChatWorkingIndicator.reasoningGlimpse("First idea.\n\nThe user asks whether **NHE** is known")
                == "The user asks whether NHE is known"
        )
        let long = String(repeating: "word ", count: 80) + "end"
        let glimpse = ReviewChatWorkingIndicator.reasoningGlimpse(long) ?? ""
        #expect(glimpse.hasPrefix("…word"))
        #expect(glimpse.hasSuffix("end"))
        #expect(glimpse.count <= 181)
    }
}

@Suite("Review chat thinking")
struct ReviewChatThinkingTests {
    @Test @MainActor func theFoldSaysHowLongTheModelThought() {
        func thought(_ duration: TimeInterval?) -> ReviewSessionManager.Message.ToolActivity {
            .init(kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
                  resultPreview: nil, reasoning: "…", thinkingDuration: duration)
        }
        #expect(ReviewChatWorkFold.title(steps: [thought(nil)], duration: nil) == "Thought")
        #expect(ReviewChatWorkFold.title(steps: [thought(0.3)], duration: nil) == "Thought for a moment")
        #expect(ReviewChatWorkFold.title(steps: [thought(8.4)], duration: nil) == "Thought for 8s")
        #expect(ReviewChatWorkFold.title(steps: [thought(59.6)], duration: nil) == "Thought for 1m")
        #expect(ReviewChatWorkFold.title(steps: [thought(96)], duration: nil) == "Thought for 1m 36s")
        // Two steps that only thought: the time each thought, added up.
        #expect(ReviewChatWorkFold.title(steps: [thought(30), thought(66)], duration: 500) == "Thought for 1m 36s")
        #expect(ReviewChatWorkFold.title(steps: [thought(30), thought(nil)], duration: 500) == "Thought")
    }

    @Test @MainActor func theFoldSaysHowLongTheReplyWorkedOrHowManyStepsItTook() {
        let search = ReviewSessionManager.Message.ToolActivity(
            toolName: "search_sources_semantic", detail: "q", state: .succeeded, resultPreview: nil
        )
        let thinking = ReviewSessionManager.Message.ToolActivity(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "…", thinkingDuration: 8
        )
        #expect(ReviewChatWorkFold.title(steps: [thinking, search], duration: 137) == "Worked for 2m 17s")
        #expect(ReviewChatWorkFold.title(steps: [search], duration: 0.2) == "Worked for a moment")
        #expect(ReviewChatWorkFold.title(steps: [thinking, search], duration: nil) == "Worked · 1 step")
        #expect(ReviewChatWorkFold.title(steps: [search, search, search], duration: nil) == "Worked · 3 steps")
        #expect(ReviewChatWorkFold.durationText(3_840) == "1h 4m")
        #expect(ReviewChatWorkFold.durationText(7_200) == "2h")
    }

    @Test @MainActor func anOpenFoldDrawsEachRunOfToolCallsAsOneCard() {
        let search = ReviewSessionManager.Message.ToolActivity(
            toolName: "search_sources_semantic", detail: "q", state: .succeeded, resultPreview: nil
        )
        let thinking = ReviewSessionManager.Message.ToolActivity(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "…", thinkingDuration: 8
        )
        let segments = ReviewChatWorkFold.segments(of: [search, search, thinking, search])
        #expect(segments.map(\.isThinking) == [false, true, false])
        #expect(segments.map { $0.steps.map(\.index) } == [[0, 1], [2], [3]])
    }

    /// One reply, as a native-tools turn leaves it: the first step's message
    /// (empty: it only called tools), its thinking, two calls, the answer's
    /// thinking and the answer. Times are the rows' own clocks.
    @MainActor
    private static func workedReply(
        start: Date,
        page: ChatWrittenPage? = nil
    ) -> [ReviewSessionManager.Message] {
        typealias Message = ReviewSessionManager.Message
        let firstStep = Message(role: .assistant, content: "", createdAt: start)
        let firstThought = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(8), toolActivity: .init(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "Find the cristae paper.", thinkingDuration: 8
        ))
        let search = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(9), toolActivity: .init(
            toolName: "search_sources_semantic", detail: "cristae", state: .succeeded, resultPreview: nil
        ))
        let write = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(40), toolActivity: .init(
            toolName: "create_doc", detail: page?.title, state: .succeeded, resultPreview: nil, writtenPage: page
        ))
        // The answer's step began at 117 s; its first words landed at 137 s.
        let answer = Message(role: .assistant, content: "Cristae fold to hold more of the chain.", createdAt: start.addingTimeInterval(117))
        let answerThought = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(137), toolActivity: .init(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "Lead with the fold.", thinkingDuration: 20
        ))
        return [firstStep, firstThought, search, write, answerThought, answer]
    }

    @Test @MainActor func aReplyFoldsEveryStepIntoOneLineAboveItsAnswer() throws {
        let page = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let messages = Self.workedReply(start: Date(timeIntervalSince1970: 1_800_000_000), page: page)
        let items = ReviewChatAnswerLayout.items(messages)

        #expect(items.count == 2)
        guard case .work(let work) = try #require(items.first) else {
            Issue.record("the reply does not open with its work: \(items)")
            return
        }
        #expect(work.id == messages[1].id)
        #expect(work.steps.map(\.toolName) == [
            ReviewSessionManager.thinkingActivityName, "search_sources_semantic", "create_doc", ReviewSessionManager.thinkingActivityName,
        ])
        #expect(work.pages == [page])
        #expect(work.answerHasBegun)
        // From the first step's start to the answer's first words.
        #expect(work.duration == 137)
        #expect(ReviewChatWorkFold.title(steps: work.steps, duration: work.duration) == "Worked for 2m 17s")
        guard case .entry(let entry) = items[1] else {
            Issue.record("the answer is not drawn after the work: \(items)")
            return
        }
        #expect(entry.message?.content == "Cristae fold to hold more of the chain.")
    }

    @Test @MainActor func aReplyStillWorkingHasNoAnswerAndNoTimeUntilItThinks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = Self.workedReply(start: start)
        // Stopped after its calls, before the answer's step: no row says when
        // the last call ended.
        let stopped = Array(messages[0...3])
        #expect(ReviewChatAnswerLayout.workDuration(stopped) == nil)
        guard case .work(let work)? = ReviewChatAnswerLayout.items(stopped).first else {
            Issue.record("no work drawn")
            return
        }
        #expect(!work.answerHasBegun)
        #expect(ReviewChatWorkFold.title(steps: work.steps, duration: work.duration) == "Worked · 2 steps")
        // Ending on thinking, the end is when that thinking ended.
        #expect(ReviewChatAnswerLayout.workDuration(Array(messages[0...1])) == 8)
        // An answer whose step did not think ends when its step began.
        #expect(ReviewChatAnswerLayout.workDuration(Array(messages[0...3]) + [messages[5]]) == 117)
    }

    @Test @MainActor func onATopicCardTheWorkHoldsNoThinking() {
        let messages = Self.workedReply(start: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .work(let work)? = ReviewChatAnswerLayout.items(messages, showsThinking: false).first else {
            Issue.record("no work drawn")
            return
        }
        #expect(work.steps.map(\.toolName) == ["search_sources_semantic", "create_doc"])
        #expect(work.id == messages[2].id)
        // A reply that only thought draws no fold there at all.
        let thoughtOnly = [messages[4], messages[5]]
        #expect(ReviewChatAnswerLayout.items(thoughtOnly, showsThinking: false).count == 1)
        #expect(ReviewChatAnswerLayout.items(thoughtOnly).count == 2)
    }

    @Test @MainActor func rowsThatStandAloneStayOutOfTheFold() {
        typealias Message = ReviewSessionManager.Message
        let cards = ChatSavedCards(cardIDs: ["c-1"], sourceIDs: ["src-1"])
        let saved = Message(role: .tool, content: "", toolActivity: .init(
            toolName: "save_card_drafts", detail: cards.label, state: .succeeded, resultPreview: nil, savedCards: cards
        ))
        let page = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let reopenedPage = Message(role: .tool, content: "", toolActivity: .init(
            toolName: ChatWrittenPage.cardRowName, detail: page.title, state: .succeeded, resultPreview: nil,
            customTitle: "Page", writtenPage: page
        ))
        let turn = Message(role: .tool, content: "", toolActivity: .init(
            kind: .sourceTurn, toolName: ReviewSessionManager.sourceTurnActivityName, detail: "topic-1",
            state: .succeeded, resultPreview: nil, customTitle: "Respiration"
        ))
        let answer = Message(role: .assistant, content: "Made from the passage.")
        let items = ReviewChatAnswerLayout.items([reopenedPage, saved, turn, answer])

        #expect(items.count == 4)
        guard case .pages(_, let pages) = items[0] else {
            Issue.record("a reopened reply's page is not a card: \(items)")
            return
        }
        #expect(pages == [page])
        guard case .entry(let cardsEntry) = items[1], case .entry(let turnEntry) = items[2] else {
            Issue.record("standalone rows were folded: \(items)")
            return
        }
        #expect(cardsEntry.savedCards == cards)
        #expect(turnEntry.activities.first?.kind == .sourceTurn)
        #expect(ReviewChatAnswerLayout.workDuration([reopenedPage, saved, turn, answer]) == nil)
    }

    /// Retry asks a failed turn again in the same answer block: the failed
    /// attempt's rows stay, its failure with them, but the retried reply is
    /// timed and carded by its own attempt (`Message.isFromFailedAttempt`).
    @Test @MainActor func aRetriedReplyIsTimedAndCardedByItsOwnAttempt() throws {
        typealias Message = ReviewSessionManager.Message
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let failedPage = ChatWrittenPage(id: "doc-0", title: "First try")
        var failed = [
            Message(role: .tool, content: "", createdAt: start, toolActivity: .init(
                toolName: "create_doc", detail: failedPage.title, state: .succeeded, resultPreview: nil, writtenPage: failedPage
            )),
            Message(role: .tool, content: "", createdAt: start.addingTimeInterval(5), toolActivity: .init(
                toolName: "search_sources_semantic", detail: "q", state: .failed, resultPreview: "timed out"
            )),
            Message(role: .assistant, content: "Let me look that up.", createdAt: start.addingTimeInterval(6)),
        ]
        for index in failed.indices { failed[index].isFromFailedAttempt = true }
        // Retried ten minutes later.
        let page = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let retried = Self.workedReply(start: start.addingTimeInterval(600), page: page)

        guard case .work(let work)? = ReviewChatAnswerLayout.items(failed + retried).first else {
            Issue.record("no work drawn")
            return
        }
        #expect(work.steps.count == 6)
        #expect(work.steps.filter { $0.state == .failed }.count == 1)
        #expect(work.pages == [page])
        #expect(work.duration == 137)
        #expect(work.answerHasBegun)

        // Retrying, before the new attempt has a step or a word: the failed
        // attempt's words are not its answer, and its page is not its card.
        let retrying = failed + [retried[0]]
        guard case .work(let pending)? = ReviewChatAnswerLayout.items(retrying).first else {
            Issue.record("no work drawn while retrying")
            return
        }
        #expect(!pending.answerHasBegun)
        #expect(pending.pages.isEmpty)
        #expect(pending.duration == nil)
    }

    @Test func thinkingSplitsIntoItsParagraphs() {
        let summary = "**Recalling the exchanger**\n\nThe paper calls it pending,\nso check NHE6.\n\n\n  \n**Checking later identifications**\n\n"
        #expect(ReviewChatReasoningText.paragraphs(summary) == [
            "**Recalling the exchanger**",
            "The paper calls it pending,\nso check NHE6.",
            "**Checking later identifications**"
        ])
        #expect(ReviewChatReasoningText.paragraphs(" \n\n ").isEmpty)
    }

    @Test func thinkingHidesTheSourceIDsItNamesSourcesBy() {
        let id = "src_5c74571a89d8c4c689ede19bc4eb69e0f9df2a322868f7d934bda82a8fe3b81a"
        let reasoning = """
        The most relevant ones would be:
        1. The Peter Attia Drive episode #46 (\(id))
        2. The Feldman Protocol episode (id: `\(id)`, \(id)).
        3. His own video, \(id), on mitochondria
        4. The Mind & Matter episode (src_0e8af68b09629b49b4f54997b9
        """
        #expect(ReviewChatReasoningText.paragraphs(reasoning) == ["""
        The most relevant ones would be:
        1. The Peter Attia Drive episode #46
        2. The Feldman Protocol episode.
        3. His own video, on mitochondria
        4. The Mind & Matter episode
        """])
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse("Reading \(id) now") == "Reading now")
        #expect(ReviewChatReasoningText.withoutSourceIDs("No ids here.  Two spaces stay.") == "No ids here.  Two spaces stay.")
    }

    @Test @MainActor func aThinkingRowStandsAloneAndStaysOutOfTheCopy() {
        let search = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(toolName: "search_sources_semantic", detail: "q", state: .succeeded, resultPreview: nil)
        )
        let thinking = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(
                kind: .thinking,
                toolName: ReviewSessionManager.thinkingActivityName,
                state: .succeeded,
                reasoning: "The therapeutic approach is mitochondrial transplantation.",
                thinkingDuration: 96
            )
        )
        let read = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(toolName: "get_source_content", detail: "A", state: .succeeded, resultPreview: nil)
        )
        let answer = ReviewSessionManager.Message(role: .assistant, content: "Transplanted mitochondria help.")

        let entries = ReviewChatTranscriptEntry.grouping([search, thinking, read, answer])

        #expect(entries.count == 4)
        #expect(entries[0].thinking == nil)
        #expect(entries[1].thinking?.reasoning == "The therapeutic approach is mitochondrial transplantation.")
        #expect(entries[2].activities.map(\.toolName) == ["get_source_content"])
        #expect(entries[3].message?.content == "Transplanted mitochondria help.")
        #expect(ReviewSessionManager.copiedAnswerText(from: [thinking, answer]) == "Transplanted mitochondria help.")
    }
}

/// A page a chat's tool wrote: a card under the reply's work, kept with the
/// reply as one link line so a reopened chat draws it again
/// (docs/chat-design.md, "Pages a chat writes").
@Suite("Chat written pages")
struct ChatWrittenPageTests {
    static let created = #"{"doc":{"id":"doc-1","title":"Cristae notes","kind":"markdown","is_archived":false,"is_hidden":false},"revision":"r1","message":"Created Doc ‘Cristae notes’."}"#

    @Test func aPageToolsResultNamesThePage() {
        #expect(ChatWrittenPage.parse(toolName: "create_doc", result: Self.created) == ChatWrittenPage(id: "doc-1", title: "Cristae notes"))
        for tool in ["write_doc", "edit_doc", "update_doc"] {
            #expect(ChatWrittenPage.parse(toolName: tool, result: Self.created)?.id == "doc-1")
        }
        // Not a page tool, not a page, gone to the Trash, hidden, or no result.
        #expect(ChatWrittenPage.parse(toolName: "read_doc", result: Self.created) == nil)
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.created.replacingOccurrences(of: #""kind":"markdown""#, with: #""kind":"animation""#)) == nil)
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.created.replacingOccurrences(of: #""is_archived":false"#, with: #""is_archived":true"#)) == nil)
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.created.replacingOccurrences(of: #""is_hidden":false"#, with: #""is_hidden":true"#)) == nil)
        #expect(ChatWrittenPage.parse(toolName: "write_doc", result: "Error: Nothing was saved.") == nil)
    }

    static let archived = created.replacingOccurrences(of: #""is_archived":false"#, with: #""is_archived":true"#)
    static let hidden = created.replacingOccurrences(of: #""is_hidden":false"#, with: #""is_hidden":true"#)
    static let deleted = #"{"status":"deleted","doc":{"id":"doc-1","title":"Cristae notes","kind":"markdown","is_archived":false,"is_hidden":false},"message":"Moved Doc ‘Cristae notes’ to the Trash."}"#

    @Test func aCallThatPutsAPageAwayNamesIt() {
        #expect(ChatWrittenPage.removedID(toolName: "update_doc", result: Self.archived) == "doc-1")
        #expect(ChatWrittenPage.removedID(toolName: "update_doc", result: Self.hidden) == "doc-1")
        #expect(ChatWrittenPage.removedID(toolName: "delete_doc", result: Self.deleted) == "doc-1")
        // A page still there, a call that writes no page, or no result.
        #expect(ChatWrittenPage.removedID(toolName: "update_doc", result: Self.created) == nil)
        #expect(ChatWrittenPage.removedID(toolName: "read_doc", result: Self.archived) == nil)
        #expect(ChatWrittenPage.removedID(toolName: "delete_doc", result: "Error: Doc not found: doc-1.") == nil)
    }

    @Test func aPageWrittenTwiceIsOneCardUnderItsLastTitle() {
        let first = ChatWrittenPage(id: "doc-1", title: "Draft")
        let other = ChatWrittenPage(id: "doc-2", title: "Other")
        let renamed = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let pages = ChatWrittenPage.adding(renamed, to: ChatWrittenPage.adding(other, to: [first]))
        #expect(pages == [renamed, other])
    }

    @Test func theStoredLineRoundTripsAndOnlyItSplits() {
        let page = ChatWrittenPage(id: "doc 1(x)", title: "Notes [draft] (v2) \\ end")
        let stored = ChatWrittenPage.storing("I wrote it up.\n\nRead it when you can.", with: [page])
        #expect(stored.hasPrefix("[Notes \\[draft\\] (v2) \\\\ end](foreverlm://doc/doc%201%28x%29?card=page)"))
        #expect(ChatWrittenPage.split(stored) == [.page(page), .text("I wrote it up.\n\nRead it when you can.")])
        #expect(ChatWrittenPage.prose(of: stored) == "I wrote it up.\n\nRead it when you can.")
        #expect(StudioEntityLink.parse(destination: page.destination) == .doc("doc 1(x)"))
        #expect(ChatWrittenPage.storing("Done.", with: []) == "Done.")

        // A page link the reply wrote itself stays prose: inline, or a line
        // of its own without the card's query.
        let inline = "See [Cristae notes](foreverlm://doc/doc-1?card=page) for more."
        #expect(ChatWrittenPage.split(inline) == [.text(inline)])
        let ownLine = "[Cristae notes](foreverlm://doc/doc-1)"
        #expect(ChatWrittenPage.split(ownLine) == [.text(ownLine)])
        #expect(ChatWrittenPage.split("[a page](https://example.com/doc/1?card=page)") == [.text("[a page](https://example.com/doc/1?card=page)")])
    }

    static let savedAnimation = #"{"status":"saved","animation_id":"anim-1","site_id":"anim-1","url":"foreverlm-site://anim-1/","doc":{"id":"anim-1","title":"Seahorse trace","kind":"animation","is_archived":false,"is_hidden":false},"message":"Saved."}"#

    @Test("An animation save_animation saved is a card that plays it, stored as its own line (product owner, 2026-11-08: \"make sure they can be rendered from a chat also\")")
    func anAnimationIsACardThatPlays() {
        let animation = ChatWrittenPage.parse(toolName: "save_animation", result: Self.savedAnimation)
        #expect(animation == ChatWrittenPage(id: "anim-1", title: "Seahorse trace", kind: .animation))
        #expect(animation?.animationURL == LinkedPage.localSiteURL(artifactID: "anim-1"))
        // A page tool naming an animation, or save_animation naming a page, is no card.
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.savedAnimation) == nil)
        #expect(ChatWrittenPage.parse(toolName: "save_animation", result: Self.created) == nil)
        #expect(ChatWrittenPage.parse(toolName: "create_doc", result: Self.created)?.animationURL == nil)

        // Stored as `card=animation`, and split back into the same card.
        let page = ChatWrittenPage(id: "doc-1", title: "Notes")
        let stored = ChatWrittenPage.storing("I made an animation.", with: [page, animation!])
        #expect(stored.contains("[Seahorse trace](foreverlm://doc/anim-1?card=animation)"))
        #expect(ChatWrittenPage.split(stored) == [.page(page), .page(animation!), .text("I made an animation.")])
        #expect(ChatWrittenPage.prose(of: "[Seahorse trace](foreverlm://doc/anim-1?card=animation)\n\nDone.") == "Done.")
        // A card value no build draws stays prose.
        let unknown = "[Seahorse trace](foreverlm://doc/anim-1?card=film)"
        #expect(ChatWrittenPage.split(unknown) == [.text(unknown)])

        // delete_animation in the same turn takes the card away.
        let deleted = #"{"status":"deleted","animation_id":"anim-1","message":"Removed."}"#
        #expect(ChatWrittenPage.removedID(toolName: "delete_animation", result: deleted) == "anim-1")
        #expect(ChatWrittenPage.removedID(toolName: "delete_animation", result: "Error: No animation of yours is named anim-1.") == nil)
        #expect(ChatWrittenPage.removedID(toolName: "save_animation", result: Self.savedAnimation) == nil)
    }

    private static let config = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "z-ai/glm-5.3-flash")

    @Test("A page a turn wrote is a card under its work, stored at the head of its reply, and a card again when the chat reopens")
    @MainActor
    func turnStoresAndReopensItsPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatWrittenPage_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Mitochondria", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        await manager.saveLearnerMessageForTesting("write this up as a page")
        manager.beginTurnForTesting()

        let row = try #require(manager.completeToolForTesting("create_doc", result: Self.created))
        let page = try #require(row.toolActivity?.writtenPage)
        #expect(page == ChatWrittenPage(id: "doc-1", title: "Cristae notes"))
        #expect(row.toolActivity?.detail == "Cristae notes")
        // A step of the work, with its page as a card under the fold.
        guard case .work(let work)? = ReviewChatAnswerLayout.items(manager.chatMessages.filter { $0.role != .user }).first else {
            Issue.record("the call is not drawn as the reply's work")
            return
        }
        #expect(work.pages == [page])

        let reply = try #require(try await manager.settleReplyForTesting("I wrote it up.", config: Self.config))
        // The row shows the prose alone and is still stamped with its exchange.
        #expect(reply.content == "I wrote it up.")
        #expect(reply.exchangeID != nil)
        let exchanges = try await storage.loadReviewSessionExchanges(sessionID: "chat")
        let stored = try #require(exchanges.first?.evaluation)
        #expect(stored == page.markdownLine + "\n\nI wrote it up.")

        let reopened = ReviewSessionManager.reconstructedWrittenPagesForTesting(from: exchanges)
        #expect(reopened.map(\.role) == ["user", "tool", "assistant"])
        #expect(reopened[1].page == page)
        #expect(reopened[2].content == "I wrote it up.")

        // The next turn wrote none: its reply carries no line.
        await manager.saveLearnerMessageForTesting("thanks")
        manager.beginTurnForTesting()
        _ = try await manager.settleReplyForTesting("You're welcome.", config: Self.config)
        let next = try await storage.loadReviewSessionExchanges(sessionID: "chat")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(next.last?.evaluation == "You're welcome.")
    }

    @Test("A page its own turn moved to the Trash or hid keeps no card and no stored line")
    @MainActor
    func aPagePutAwayInItsTurnLeavesNoCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatWrittenPage_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Mitochondria", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        await manager.saveLearnerMessageForTesting("draft two pages, then bin the first")
        manager.beginTurnForTesting()

        let created = try #require(manager.completeToolForTesting("create_doc", result: Self.created))
        let kept = ChatWrittenPage(id: "doc-2", title: "Kept")
        _ = manager.completeToolForTesting("write_doc", result: #"{"doc":{"id":"doc-2","title":"Kept","kind":"markdown"}}"#)
        _ = manager.completeToolForTesting("delete_doc", result: Self.deleted)
        #expect(manager.chatMessages.first { $0.id == created.id }?.toolActivity?.writtenPage == nil)
        guard case .work(let work)? = ReviewChatAnswerLayout.items(manager.chatMessages.filter { $0.role != .user }).first else {
            Issue.record("the calls are not drawn as the reply's work")
            return
        }
        #expect(work.pages == [kept])
        _ = try await manager.settleReplyForTesting("Done.", config: Self.config)
        let first = try await storage.loadReviewSessionExchanges(sessionID: "chat")
        #expect(first.first?.evaluation == kept.markdownLine + "\n\nDone.")

        // Hidden by a later call of its turn: the same.
        await manager.saveLearnerMessageForTesting("make one more, then hide it")
        manager.beginTurnForTesting()
        let again = try #require(manager.completeToolForTesting("create_doc", result: Self.created))
        _ = manager.completeToolForTesting("update_doc", result: Self.hidden)
        #expect(manager.chatMessages.first { $0.id == again.id }?.toolActivity?.writtenPage == nil)
        _ = try await manager.settleReplyForTesting("Hidden.", config: Self.config)
        let next = try await storage.loadReviewSessionExchanges(sessionID: "chat")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(next.last?.evaluation == "Hidden.")
    }
}

/// The "Don't let AI providers keep my data" switch: what it puts on the wire,
/// where it stays off the wire, and how OpenRouter's refusal reads back.
@Suite("AI data policy", .serialized)
struct AIDataPolicyTests {
    /// Runs `body` with the switch in the given state and restores whatever the
    /// developer's own defaults held.
    private func withDataPolicy(deny: Bool, _ body: () async throws -> Void) async throws {
        let key = AIDataPolicy.denyDataCollectionKey
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set(deny, forKey: key)
        try await body()
    }

    @Test("OpenRouter bodies carry data_collection deny only while the switch is on")
    func openRouterBodiesCarryTheDenyPreferenceOnlyWhenOn() async throws {
        let payload: [String: Any] = [
            "model": "deepseek/deepseek-v4-flash",
            "messages": [["role": "user", "content": "Summarise the abstract."]],
            "max_tokens": 512,
        ]

        try await withDataPolicy(deny: true) {
            let prepared = try AIService.prepareOpenAICompatiblePayload(payload, provider: .openRouter)
            #expect(AIDataPolicy.payloadDeniesDataCollection(prepared))
            let provider = try #require(prepared["provider"] as? [String: Any])
            #expect(provider["data_collection"] as? String == "deny")

            // First-party routes take no such flag; nothing is invented for them.
            let openAI = try AIService.prepareOpenAICompatiblePayload(payload, provider: .openai)
            #expect(openAI["provider"] == nil)
        }

        try await withDataPolicy(deny: false) {
            let prepared = try AIService.prepareOpenAICompatiblePayload(payload, provider: .openRouter)
            // Only the fastest-endpoint sort rides along; no data policy.
            #expect((prepared["provider"] as? [String: Any])?["data_collection"] == nil)
            #expect((prepared["provider"] as? [String: Any])?["sort"] as? String == "throughput")
            #expect(!AIDataPolicy.payloadDeniesDataCollection(prepared))
        }
    }

    @Test("Existing provider preferences survive the deny flag")
    func denyFlagKeepsOtherProviderPreferences() {
        var payload: [String: Any] = ["provider": ["order": ["Together"]]]
        AIDataPolicy.applyDenyDataCollection(to: &payload)
        let provider = payload["provider"] as? [String: Any]
        #expect(provider?["order"] as? [String] == ["Together"])
        #expect(provider?["data_collection"] as? String == "deny")
    }

    @Test("The phone's OpenRouter body carries the flag from its resolved route")
    func mobileRouteCarriesTheFlag() throws {
        func body(deny: Bool) throws -> [String: Any] {
            let route = ResolvedAITextRoute(
                task: .chat,
                provider: "OpenRouter",
                model: "deepseek/deepseek-v4-flash",
                deniesDataCollection: deny
            )
            let request = try MobileOpenRouterChat.request(
                route: route,
                system: "You answer from the source.",
                messages: [(role: "user", content: "What is the main claim?")],
                maxTokens: 256
            )
            let data = try #require(request.httpBody)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(AIDataPolicy.payloadDeniesDataCollection(try body(deny: true)))
        let open = try body(deny: false)
        #expect(!AIDataPolicy.payloadDeniesDataCollection(open))
        #expect((open["provider"] as? [String: Any])?["sort"] as? String == "throughput")
    }

    @Test("OpenRouter's data-policy refusal names the switch, only while it is on")
    func dataPolicyRefusalNamesTheSwitch() async throws {
        let refusal = #"{"error":{"message":"No endpoints found matching your data policy","code":404}}"#
        let service = AIService()

        try await withDataPolicy(deny: true) {
            let message = try #require(await service.extractAPIErrorMessage(from: Data(refusal.utf8)))
            #expect(message.contains(AIDataPolicy.switchTitle))
            #expect(message.contains(AIDataPolicy.settingsLocation))
            #expect(message.hasSuffix("The provider said: No endpoints found matching your data policy"))
            #expect(message.count <= AIProviderErrorText.maximumDisplayLength)

            // Any other refusal is the provider's own words, untouched.
            let rateLimit = #"{"error":{"message":"Rate limit reached"}}"#
            #expect(await service.extractAPIErrorMessage(from: Data(rateLimit.utf8)) == "Rate limit reached")
        }

        try await withDataPolicy(deny: false) {
            #expect(await service.extractAPIErrorMessage(from: Data(refusal.utf8))
                == "No endpoints found matching your data policy")
        }
    }

    /// OpenRouter's answer to Muse Spark 1.2 Contributor on 2026-09-10, verbatim.
    static let trainingRefusalText = "0 endpoints out of 1 requested are available matching your guardrail "
        + "restrictions and data policy. We removed them for the following reasons (an endpoint may have "
        + "matched multiple reasons): Paid model training violation (account settings): 1 endpoint excluded; "
        + "configurable at https://openrouter.ai/settings/privacy"

    @Test("The account's training refusal is translated whether or not the switch is on")
    func trainingRefusalIsTranslatedWithoutTheSwitch() async throws {
        let refusal = try JSONSerialization.data(withJSONObject: [
            "error": ["message": Self.trainingRefusalText, "code": 404],
        ])
        let service = AIService()

        for deny in [false, true] {
            try await withDataPolicy(deny: deny) {
                let message = try #require(await service.extractAPIErrorMessage(from: refusal))
                #expect(message.hasPrefix("This model is served only by hosts that train on what you send them"))
                // The switch is not the way out of an account-level exclusion.
                #expect(!message.contains(AIDataPolicy.switchTitle))
                #expect(message.contains("The provider said: 0 endpoints out of 1 requested"))
                #expect(message.count <= AIProviderErrorText.maximumDisplayLength)
            }
        }
    }

    @Test("The switch hides the models that train from every catalog read")
    func switchHidesTrainingModels() async throws {
        let contributor = AIModelCatalogEntry(
            maker: .meta, provider: .meta, modelID: AIModelDefaults.museSparkContributor
        )
        let contributorSlug = "meta/\(AIModelDefaults.museSparkContributor)"

        try await withDataPolicy(deny: false) {
            #expect(!AIModelCatalog.hidesTrainingModels)
            let entry = try #require(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.museSparkContributor))
            #expect(entry.trainsOnInputs)
            #expect(AIModelCatalog.makerGroups.flatMap(\.entries).contains(where: { $0.id == contributor.id }))
            #expect(AIModelCatalog.allEntries.contains(where: { $0.id == contributor.id }))
            #expect(AIModelCatalog.isEnabledChatSelection(
                provider: .meta, modelID: AIModelDefaults.museSparkContributor, enabledIDs: [contributor.id]
            ))
            // No row says the model trains: that is OpenRouter's to say. The
            // picker is the main actor's, so the row is read on it.
            await MainActor.run {
                #expect(InlineModelPicker.modelRowSubtitle(
                    rates: (input: 0.1, output: 0.2), promotion: nil, currentSpeedQuote: nil
                ) == "$0.1/$0.2")
                #expect(InlineModelPicker.modelRowSubtitle(rates: nil, promotion: nil, currentSpeedQuote: nil) == nil)
                #expect(InlineModelPicker.modelRowSubtitle(
                    rates: nil, promotion: nil, currentSpeedQuote: nil, isRecommended: true
                ) == "Recommended")
            }
        }

        try await withDataPolicy(deny: true) {
            #expect(AIModelCatalog.hidesTrainingModels)
            #expect(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.museSparkContributor) == nil)
            #expect(!AIModelCatalog.makerGroups.flatMap(\.entries).contains { $0.trainsOnInputs })
            #expect(!AIModelCatalog.allEntries.contains { $0.trainsOnInputs })
            #expect(!AIModelCatalog.isEnabledChatSelection(
                provider: .meta, modelID: AIModelDefaults.museSparkContributor, enabledIDs: [contributor.id]
            ))
            // Still catalogued for the directory browser, so it is not offered
            // back as an extra while hidden.
            #expect(AIModelCatalog.cataloguedOpenRouterSlugs.contains(contributorSlug))
            // The full tier is untouched, and Meta's group survives.
            #expect(AIModelCatalog.entry(provider: .meta, modelID: AIModelDefaults.latestMuseSpark) != nil)
            #expect(AIModelCatalog.makerGroups.contains(where: { $0.maker == .meta }))
        }
    }

    @Test("Refusal detection reads the words, not the status")
    func refusalDetectionReadsTheWords() {
        #expect(AIDataPolicy.isDataPolicyRefusal("No endpoints found matching your data policy"))
        #expect(AIDataPolicy.isDataPolicyRefusal("Provider rejected: data_collection=deny excludes all hosts"))
        #expect(!AIDataPolicy.isDataPolicyRefusal("No endpoints found that support image input"))
        #expect(!AIDataPolicy.isDataPolicyRefusal("Rate limit reached"))

        // The account-level exclusion mentions "data policy" too; it is told
        // apart by the training clause and wins.
        #expect(AIDataPolicy.isTrainingPolicyRefusal(Self.trainingRefusalText))
        #expect(AIDataPolicy.isDataPolicyRefusal(Self.trainingRefusalText))
        #expect(!AIDataPolicy.isTrainingPolicyRefusal("No endpoints found matching your data policy"))
        #expect(!AIDataPolicy.isTrainingPolicyRefusal("Rate limit reached"))
    }

    @Test("The switch is a synced preference")
    func switchIsSynced() {
        #expect(SyncedPreferenceKeys.isSynced(AIDataPolicy.denyDataCollectionKey))
    }
}

@Suite("OpenRouter speed tiers", .serialized)
struct OpenRouterSpeedTierTests {
    /// Trimmed from OpenRouter's live `/models/openai/gpt-5.6-sol/endpoints`
    /// answer on 2026-09-10: the lab's three service tiers plus two resellers.
    static let solEndpointsJSON = """
    {"data":{"id":"openai/gpt-5.6-sol","name":"OpenAI: GPT-5.6 Sol","endpoints":[
      {"name":"OpenAI | openai/gpt-5.6-sol-20260709","tag":"openai/flex","provider_name":"OpenAI","status":-2,
       "pricing":{"prompt":"0.000001","completion":"0.000005","input_cache_read":"0.0000001","discount":0.5}},
      {"name":"OpenAI | openai/gpt-5.6-sol-20260709","tag":"openai","provider_name":"OpenAI","status":0,
       "pricing":{"prompt":"0.000002","completion":"0.00001","input_cache_read":"0.0000002","discount":0.5}},
      {"name":"OpenAI | openai/gpt-5.6-sol-20260709","tag":"openai/fast","provider_name":"OpenAI","status":0,
       "pricing":{"prompt":"0.000004","completion":"0.00002","input_cache_read":"0.0000004","discount":0.5}},
      {"name":"Azure | openai/gpt-5.6-sol-20260709","tag":"azure/eu","provider_name":"Azure","status":0,
       "pricing":{"prompt":"0.0000055","completion":"0.000033","input_cache_read":"0.00000055","discount":0}},
      {"name":"Broken | openai/gpt-5.6-sol-20260709","tag":"broken/fast","provider_name":"Broken","status":-3,
       "pricing":{"prompt":"0.000001","completion":"0.000001"}},
      {"name":"No price","tag":"nowhere","provider_name":"Nowhere","status":0,"pricing":{}}
    ]}}
    """

    static var solTiers: [OpenRouterEndpointTier] {
        OpenRouterSpeedTier.parseEndpoints(Data(solEndpointsJSON.utf8))
    }

    @Test("Endpoint rows parse into priced tiers, keeping deranked ones and dropping unpriced ones")
    func endpointsParse() throws {
        let tiers = Self.solTiers
        // Flex is at status -2 in the live answer — OpenRouter's derank
        // marker, not an outage — and must still be offered; the row with
        // no price is the only one that goes.
        #expect(tiers.map(\.tag) == ["openai/flex", "openai", "openai/fast", "azure/eu", "broken/fast"])
        let fast = try #require(OpenRouterSpeedTier.fastTier(for: "openai/gpt-5.6-sol", in: tiers))
        #expect(fast.tag == "openai/fast")
        #expect(fast.providerName == "OpenAI")
        #expect(fast.inputUSDPerMTokens == 4)
        #expect(fast.outputUSDPerMTokens == 20)
        #expect(fast.cachedInputUSDPerMTokens == 0.4)
        #expect(fast.discount == 0.5)
        let standard = try #require(OpenRouterSpeedTier.standardTier(for: "openai/gpt-5.6-sol", in: tiers))
        #expect(standard.tag == "openai")
        #expect(standard.inputUSDPerMTokens == 2)
        #expect(standard.outputUSDPerMTokens == 10)
        let flex = try #require(OpenRouterSpeedTier.flexTier(for: "openai/gpt-5.6-sol", in: tiers))
        #expect(flex.tag == "openai/flex")
        #expect(flex.inputUSDPerMTokens == 1)
        #expect(flex.outputUSDPerMTokens == 5)
        #expect(OpenRouterSpeedTier.tier(for: .flex, slug: "openai/gpt-5.6-sol", in: tiers) == flex)
        #expect(OpenRouterSpeedTier.tier(for: .standard, slug: "openai/gpt-5.6-sol", in: tiers) == standard)
        #expect(OpenRouterSpeedTier.tier(for: .fast, slug: "openai/gpt-5.6-sol", in: tiers) == fast)
        // Azure's row carries no promotion, so its discount reads as none.
        #expect(tiers.last?.discount == nil)
    }

    @Test("Only the lab's own fast tier counts")
    func fastTierBelongsToTheLab() {
        let reseller = [OpenRouterEndpointTier(
            tag: "deepinfra/fast", providerName: "DeepInfra",
            inputUSDPerMTokens: 1, outputUSDPerMTokens: 2,
            cachedInputUSDPerMTokens: nil, discount: nil)]
        #expect(OpenRouterSpeedTier.fastTier(for: "openai/gpt-5.6-sol", in: reseller) == nil)
        #expect(OpenRouterSpeedTier.fastTier(for: "no-vendor-slug", in: Self.solTiers) == nil)
        #expect(OpenRouterSpeedTier.vendor(ofSlug: "Anthropic/claude-opus-5") == "anthropic")
    }

    @Test("Promotion labels name whole percents only")
    func promotionLabels() {
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 0.5) == "50% off")
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 0.25) == "25% off")
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 0) == nil)
        #expect(OpenRouterSpeedTier.promotionLabel(discount: nil) == nil)
        #expect(OpenRouterSpeedTier.promotionLabel(discount: 1) == nil)
        // The composer menu carries the fraction too, so it can strike the
        // list price beside the discounted one.
        #expect(OpenRouterSpeedTier.promotion(discount: 0.5)
            == RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil))
        #expect(OpenRouterSpeedTier.promotion(discount: 0.25)?.discountBasisPoints == 2_500)
        #expect(OpenRouterSpeedTier.promotion(discount: 0) == nil)
        #expect(OpenRouterSpeedTier.promotion(discount: nil) == nil)
        #expect(OpenRouterSpeedTier.promotion(discount: 1) == nil)
    }

    @Test("Speed is offered only where OpenRouter lists a tier endpoint for the routed slug, cheapest first")
    func speedSupportFollowsTheRoute() {
        let slug = "openai/gpt-5.6-sol"
        OpenRouterEndpointTierCatalog.cache(Self.solTiers, for: slug)
        defer { OpenRouterEndpointTierCatalog.cache([], for: slug) }

        // The composer's canonical identity, on the OpenRouter route: OpenAI
        // publishes both a flex and a fast tier, listed as a price ladder.
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openai, model: "gpt-5.6", routingMode: .openRouter) == [.flex, .standard, .fast])
        // The dispatch path's routed identity.
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openRouter, model: slug, routingMode: .openRouter) == [.flex, .standard, .fast])
        // A lab with only a fast tier (Anthropic) offers Standard and Fast; one
        // with only a flex tier offers Flex and Standard; a lab with neither
        // offers no Speed control even though its endpoints are known.
        let opus = "anthropic/claude-opus-5"
        OpenRouterEndpointTierCatalog.cache([
            OpenRouterEndpointTier(tag: "anthropic", providerName: "Anthropic",
                                   inputUSDPerMTokens: 5, outputUSDPerMTokens: 25, cachedInputUSDPerMTokens: nil, discount: nil),
            OpenRouterEndpointTier(tag: "anthropic/fast", providerName: "Anthropic",
                                   inputUSDPerMTokens: 30, outputUSDPerMTokens: 150, cachedInputUSDPerMTokens: nil, discount: nil),
        ], for: opus)
        defer { OpenRouterEndpointTierCatalog.cache([], for: opus) }
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .anthropic, model: "claude-opus-5", routingMode: .openRouter) == [.standard, .fast])
        let flexOnly = "openai/gpt-5.6-luna"
        OpenRouterEndpointTierCatalog.cache([
            OpenRouterEndpointTier(tag: "openai", providerName: "OpenAI",
                                   inputUSDPerMTokens: 0.2, outputUSDPerMTokens: 1.2, cachedInputUSDPerMTokens: nil, discount: nil),
            OpenRouterEndpointTier(tag: "openai/flex", providerName: "OpenAI",
                                   inputUSDPerMTokens: 0.1, outputUSDPerMTokens: 0.6, cachedInputUSDPerMTokens: nil, discount: nil),
        ], for: flexOnly)
        defer { OpenRouterEndpointTierCatalog.cache([], for: flexOnly) }
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openai, model: "gpt-5.6-luna", routingMode: .openRouter) == [.flex, .standard])
        let plain = "nvidia/nemotron-3-ultra"
        OpenRouterEndpointTierCatalog.cache([
            OpenRouterEndpointTier(tag: "nvidia", providerName: "NVIDIA",
                                   inputUSDPerMTokens: 0.62, outputUSDPerMTokens: 3.12, cachedInputUSDPerMTokens: nil, discount: nil),
        ], for: plain)
        defer { OpenRouterEndpointTierCatalog.cache([], for: plain) }
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .openRouter, model: plain, routingMode: .openRouter).isEmpty)
        // A model whose endpoints have not been fetched offers nothing yet.
        #expect(AIRequestOptionSupport.supportedSpeeds(
            provider: .anthropic, model: "claude-sonnet-5", routingMode: .openRouter).isEmpty)
        #expect(AIRequestOptionSupport.openRouterSpeedSlug(
            provider: .anthropic, model: "claude-opus-4-8", routingMode: .openRouter) == "anthropic/claude-opus-4.8")
    }

    @Test("Fast and Flex name the lab's tier endpoint in provider.order and forbid fallbacks")
    func fastRequestTargetsTheTier() throws {
        let slug = "openai/gpt-5.6-sol"
        OpenRouterEndpointTierCatalog.cache(Self.solTiers, for: slug)
        defer { OpenRouterEndpointTierCatalog.cache([], for: slug) }
        func payload() -> [String: Any] {
            [
                "model": slug,
                "messages": [
                    ["role": "system", "content": "instructions"],
                    ["role": "user", "content": "question"],
                ] as [[String: Any]],
            ]
        }

        var fast = payload()
        AIService.applyOpenRouterPayloadExtras(&fast, provider: .openRouter, speed: .fast)
        let provider = try #require(fast["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["openai/fast"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        // The model id is unchanged, so the prompt cache is shared across speeds.
        #expect(fast["model"] as? String == slug)

        var flex = payload()
        AIService.applyOpenRouterPayloadExtras(&flex, provider: .openRouter, speed: .flex)
        let flexProvider = try #require(flex["provider"] as? [String: Any])
        #expect(flexProvider["order"] as? [String] == ["openai/flex"])
        #expect(flexProvider["allow_fallbacks"] as? Bool == false)

        var standard = payload()
        AIService.applyOpenRouterPayloadExtras(&standard, provider: .openRouter, speed: .standard)
        #expect((standard["provider"] as? [String: Any])?["order"] == nil)

        var unknownTier = payload()
        unknownTier["model"] = "anthropic/claude-opus-5"
        AIService.applyOpenRouterPayloadExtras(&unknownTier, provider: .openRouter, speed: .fast)
        #expect((unknownTier["provider"] as? [String: Any])?["order"] == nil)

        // An existing provider preference (the data-policy switch) is kept.
        var merged = payload()
        merged["provider"] = ["data_collection": "deny"]
        AIService.applyOpenRouterSpeedTier(to: &merged, speed: .fast)
        let mergedProvider = try #require(merged["provider"] as? [String: Any])
        #expect(mergedProvider["data_collection"] as? String == "deny")
        #expect(mergedProvider["order"] as? [String] == ["openai/fast"])
    }

    @Test("A standard OpenRouter send goes to the fastest endpoint that caches the prompt")
    func standardSendSortsByThroughputAmongCachingEndpoints() throws {
        func endpoint(_ tag: String, cached: Double?, parameters: Set<String>? = ["tools", "reasoning", "max_tokens"]) -> OpenRouterEndpointTier {
            OpenRouterEndpointTier(tag: tag, providerName: tag, inputUSDPerMTokens: 0.15, outputUSDPerMTokens: 0.6,
                                   cachedInputUSDPerMTokens: cached, discount: nil, supportedParameters: parameters)
        }
        let slug = "openai/gpt-oss-120b"
        let mixed = [
            endpoint("cerebras/fp16", cached: nil),
            endpoint("fireworks", cached: 0.03),
            endpoint("groq", cached: 0.075),
            endpoint("together", cached: 0.15), // cached == prompt: nothing to gain
            endpoint("novita/fp4", cached: 0.03, parameters: ["max_tokens"]),
        ]
        OpenRouterEndpointTierCatalog.cache(mixed, for: slug)
        defer { OpenRouterEndpointTierCatalog.cache([], for: slug) }

        var chat: [String: Any] = [
            "model": slug,
            "messages": [["role": "system", "content": "s"], ["role": "user", "content": "q"]] as [[String: Any]],
            "tools": [["type": "function"]] as [[String: Any]],
        ]
        // The switch withholds `only`; pin it off, then restore the developer's own.
        let policyKey = AIDataPolicy.denyDataCollectionKey
        let savedPolicy = UserDefaults.standard.object(forKey: policyKey)
        defer {
            if let savedPolicy { UserDefaults.standard.set(savedPolicy, forKey: policyKey) }
            else { UserDefaults.standard.removeObject(forKey: policyKey) }
        }
        UserDefaults.standard.set(false, forKey: policyKey)
        AIService.applyOpenRouterPayloadExtras(&chat, provider: .openRouter, speed: .standard)
        let provider = try #require(chat["provider"] as? [String: Any])
        #expect(provider["sort"] as? String == "throughput")
        // The endpoint without tools is dropped, so the send cannot fail on it.
        #expect(provider["only"] as? [String] == ["fireworks", "groq"])

        // Every endpoint caches (GLM 5.3 Flash's 30 hosts): nothing to confine.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("z-ai/fp8", cached: 0.03), endpoint("wafer", cached: 0.02)],
            requiredParameters: ["tools"]) == nil)
        // None caches: nothing to confine to.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("cerebras", cached: nil), endpoint("sambanova", cached: nil)],
            requiredParameters: []) == nil)
        // An endpoint that does not list its parameters could be the only fit: leave routing open.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("cerebras", cached: nil), endpoint("fireworks", cached: 0.03, parameters: nil)],
            requiredParameters: []) == nil)
        // Service tiers never join a standard request's list.
        #expect(OpenRouterSpeedTier.promptCachingEndpointTags(
            in: [endpoint("openai", cached: nil), endpoint("openai/flex", cached: 0.1)],
            requiredParameters: []) == nil)
    }

    @Test("The caching filter stands down under the data-policy switch, and a Speed pick keeps its endpoint")
    func cachingFilterYieldsToDataPolicyAndSpeedPicks() {
        var denied: [String: Any] = ["model": "m", "provider": ["data_collection": "deny"]]
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &denied, cachingEndpointTags: ["fireworks"])
        let deniedProvider = denied["provider"] as? [String: Any]
        #expect(deniedProvider?["sort"] as? String == "throughput")
        #expect(deniedProvider?["only"] == nil)

        var pinned: [String: Any] = ["model": "m", "provider": ["order": ["openai/fast"], "allow_fallbacks": false]]
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &pinned, cachingEndpointTags: ["fireworks"])
        let pinnedProvider = pinned["provider"] as? [String: Any]
        #expect(pinnedProvider?["sort"] == nil)
        #expect(pinnedProvider?["only"] == nil)

        #expect(OpenRouterRoutePreference.requiredParameters(of: [
            "tools": [["type": "function"]], "reasoning_effort": "low", "response_format": ["type": "json_object"],
        ]) == ["tools", "reasoning", "response_format"])
        #expect(OpenRouterRoutePreference.requiredParameters(of: ["tools": [Any]()]).isEmpty)
    }

    @Test("A host chosen for a task names it, or asks for the cheapest, and a task follows its Background default's choice")
    func hostPreferencePinsOrSortsTheRoute() throws {
        var cheapest: [String: Any] = ["model": "z-ai/glm-5.3"]
        OpenRouterHostPreference(mode: .cheapest).apply(to: &cheapest)
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &cheapest)
        #expect((cheapest["provider"] as? [String: Any])?["sort"] as? String == "price")

        var pinned: [String: Any] = ["model": "z-ai/glm-5.3"]
        OpenRouterHostPreference(mode: .host, tag: "deepinfra/fp4", hostName: "DeepInfra", allowsFallback: false)
            .apply(to: &pinned)
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &pinned, cachingEndpointTags: ["fireworks"])
        let provider = try #require(pinned["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["deepinfra/fp4"])
        #expect(provider["allow_fallbacks"] as? Bool == false)
        #expect(provider["sort"] == nil)
        #expect(provider["only"] == nil)

        #expect(!OpenRouterHostPreference(mode: .host, tag: " ").isValid)
        #expect(OpenRouterHostPreference(mode: .cheapest, tag: "ignored").tag == nil)
        #expect(OpenRouterHostPreference.key(slot: "background.text", slug: "Z-AI/GLM-5.3")
            == "aiHost.background.text|z-ai/glm-5.3")

        #expect(AIService.openRouterHostSlots(forTaskLabel: "chat") == ["chat"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: nil).isEmpty)
        // A chat's title runs on Background's model, so it follows that row.
        #expect(AIService.openRouterHostSlots(forTaskLabel: "chat_title") == ["background.text"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: "chat_quiz_grading") == ["chat"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: "read_aloud").isEmpty)
        // A background task follows its Background model's row alone: no
        // task has a host choice of its own.
        #expect(AIService.openRouterHostSlots(forTaskLabel: AITask.paperMetadata.rawValue) == ["background.text"])
        #expect(AIService.openRouterHostSlots(forTaskLabel: AITask.paperFigureUnderstanding.rawValue) == ["background.images"])
    }

    @Test("Endpoint rows carry their supported parameters")
    func endpointRowsCarrySupportedParameters() throws {
        let json = #"{"data":{"endpoints":[{"tag":"fireworks","provider_name":"Fireworks","pricing":{"prompt":"0.00000015","completion":"0.0000006","input_cache_read":"0.00000003"},"supported_parameters":["tools","reasoning"]}]}}"#
        let row = try #require(OpenRouterSpeedTier.parseEndpoints(Data(json.utf8)).first)
        #expect(row.supportedParameters == ["tools", "reasoning"])
        #expect(row.cachesPrompts)
    }

    @Test("The directory is fetched without a tool filter, which priced OpenAI models at their Flex tier")
    func directoryRequestCarriesNoParameterFilter() throws {
        let components = try #require(URLComponents(url: AIService.openRouterDirectoryURL, resolvingAgainstBaseURL: false))
        #expect(components.host == "openrouter.ai")
        #expect(components.path == "/api/v1/models")
        let names = Set((components.queryItems ?? []).map(\.name))
        #expect(!names.contains("supported_parameters"))
    }

    @Test("Output speed comes from OpenRouter's measured medians, per tier, and follows the price in the Speed submenu only")
    func composerOutputSpeedCopy() throws {
        // The shape /api/frontend/v1/stats/endpoint returned for GPT-5.6 Sol on
        // 2026-09-22, trimmed to the fields read. azure/us had no traffic.
        let body = """
        {"data":[
          {"provider_slug":"openai/flex","stats":{"p50_throughput":48,"throughput_request_count":1316}},
          {"provider_slug":"openai","stats":{"p50_throughput":49,"throughput_request_count":54399}},
          {"provider_slug":"openai/fast","stats":{"p50_throughput":84,"throughput_request_count":641}},
          {"provider_slug":"amazon-bedrock/us-east-1","stats":{"p50_throughput":81,"throughput_request_count":1083}},
          {"provider_slug":"azure","stats":{"p50_throughput":52,"throughput_request_count":30311}},
          {"provider_slug":"lone-host","stats":{"p50_throughput":400,"throughput_request_count":1}},
          {"provider_slug":"azure/us","stats":null}
        ]}
        """
        let speeds = OpenRouterModelSpeed.parseStats(Data(body.utf8))
        #expect(speeds.count == 6)
        let slug = "openai/gpt-5.6-sol"
        // Fast and Flex are their tier endpoint; Standard is the fastest
        // standard host with enough traffic — never the one-request outlier.
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .fast, slug: slug, in: speeds) == 84)
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .flex, slug: slug, in: speeds) == 48)
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: slug, in: speeds) == 81)
        #expect(OpenRouterModelSpeed.tokensPerSecond(for: .standard, slug: slug, in: []) == nil)
        #expect(OpenRouterModelSpeed.parseStats(Data("{\"data\":{}}".utf8)).isEmpty)
        #expect(OpenRouterModelSpeed.label(tokensPerSecond: 60.6) == "61 tok/s")

        let fast = try #require(InlineModelPicker.speedRates(
            for: .fast, slug: slug, tiers: Self.solTiers, standardFallback: nil, speeds: speeds))
        #expect(fast.subtitle == "\(Self.struck("$8/$40")) $4/$20 · 50% off · 84 tok/s")
        // The model rows quote the price alone (product owner, 2026-09-23), even
        // for the selected model whose speed quote carries a figure.
        #expect(fast.priceLine == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 2, output: 10), promotion: nil, currentSpeedQuote: fast)
            == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        #expect(!InlineModelPicker.priceUnitHeader.contains("speed"))
        #expect(InlineModelPicker.speedPriceUnitHeader
            == "Price per million tokens, input/output · output speed")

        #expect(OpenRouterModelPage.url(slug: "anthropic/claude-sonnet-5")?.absoluteString
            == "https://openrouter.ai/anthropic/claude-sonnet-5")
        #expect(OpenRouterModelPage.url(provider: .openRouter, model: "z-ai/glm-5.3-flash")?.absoluteString
            == "https://openrouter.ai/z-ai/glm-5.3-flash")
        #expect(OpenRouterModelPage.url(slug: "no-vendor") == nil)
    }

    @Test("The composer quotes each speed from its own endpoint row and names the promotion once")
    func composerSpeedAndPromotionCopy() throws {
        let slug = "openai/gpt-5.6-sol"
        let tiers = Self.solTiers
        let fast = try #require(InlineModelPicker.speedRates(
            for: .fast, slug: slug, tiers: tiers, standardFallback: (input: 5, output: 30)))
        #expect(fast.input == 4)
        #expect(fast.output == 20)
        #expect(fast.subtitle == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        let standard = try #require(InlineModelPicker.speedRates(
            for: .standard, slug: slug, tiers: tiers, standardFallback: (input: 5, output: 30)))
        #expect(standard.input == 2)
        #expect(standard.output == 10)
        #expect(standard.subtitle == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        let flex = try #require(InlineModelPicker.speedRates(
            for: .flex, slug: slug, tiers: tiers, standardFallback: (input: 5, output: 30)))
        #expect(flex.input == 1)
        #expect(flex.output == 5)
        #expect(flex.subtitle == "\(Self.struck("$2/$10")) $1/$5 · 50% off")
        // No endpoint list yet: Standard falls back to the list price with the
        // route's own promotion label; Flex and Fast have nothing to quote.
        let fallback = try #require(InlineModelPicker.speedRates(
            for: .standard, slug: slug, tiers: [], standardFallback: (input: 2, output: 10),
            standardFallbackPromotion: Self.halfOff))
        #expect(fallback.input == 2)
        #expect(fallback.output == 10)
        #expect(fallback.subtitle == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        #expect(InlineModelPicker.speedRates(
            for: .fast, slug: slug, tiers: [], standardFallback: (input: 5, output: 30)) == nil)
        #expect(InlineModelPicker.speedRates(
            for: .flex, slug: slug, tiers: [], standardFallback: (input: 5, output: 30)) == nil)

        // A promoted line leads the in/out pair with the list pair, struck
        // through, so "50% off" cannot be read as still to come (product owner,
        // 2026-09-21). The strike is the U+0336 overlay, the only one a
        // macOS menu subtitle keeps; a list figure that rounds to the
        // effective label is left alone, and a free model has nothing to
        // strike.
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 2, output: 10), promotion: Self.halfOff)
            == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 2, output: 10), promotion: Self.halfOff)
            == "$\u{0336}4\u{0336}/\u{0336}$\u{0336}2\u{0336}0\u{0336} $2/$10 · 50% off")
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 2.5, output: 15), promotion: nil)
            == "$2.5/$15")
        #expect(InlineModelPicker.menuSubtitle(
            rates: (input: 0.01, output: 1),
            promotion: RouterModelPromotion(label: "1% off", discountBasisPoints: 100, endsAt: nil))
            == "\(Self.struck("$0.01/$1.01")) $0.01/$1 · 1% off")
        #expect(InlineModelPicker.menuSubtitle(rates: (input: 0, output: 0), promotion: Self.halfOff)
            == "$0/$0 · 50% off")
        #expect(InlineModelPicker.menuSubtitle(
            rates: (input: 2, output: 10),
            promotion: RouterModelPromotion(label: "Free week", discountBasisPoints: 10_000, endsAt: nil))
            == "$2/$10 · Free week")
        #expect(InlineModelPicker.struckThrough("$20") == "$\u{0336}2\u{0336}0\u{0336}")

        // The selected model's row is priced from the speed it is set to, so
        // it can never contradict the Speed submenu; every other row (and the
        // selected one before the endpoint list arrives) quotes the directory.
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 1, output: 5), promotion: Self.halfOff, currentSpeedQuote: standard)
            == "\(Self.struck("$4/$20")) $2/$10 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 1, output: 5), promotion: Self.halfOff, currentSpeedQuote: fast)
            == "\(Self.struck("$8/$40")) $4/$20 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(
            rates: (input: 1, output: 5), promotion: Self.halfOff, currentSpeedQuote: nil)
            == "\(Self.struck("$2/$10")) $1/$5 · 50% off")
        #expect(InlineModelPicker.modelRowSubtitle(rates: nil, promotion: nil, currentSpeedQuote: nil) == nil)

        let entry = AIModelCatalogEntry(maker: .openai, provider: .openai, modelID: "gpt-5.6")
        let directory = [OpenRouterDirectoryModel(
            id: slug, name: "GPT-5.6 Sol",
            inputUSDPerMTokens: 2, outputUSDPerMTokens: 10, contextLength: 1_050_000,
            price: nil, supportsTools: true, supportsTemperature: nil, supportsVision: true,
            promotion: RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil))]
        #expect(InlineModelPicker.promotion(for: entry, routingMode: .openRouter, directory: directory) == Self.halfOff)
    }

    /// OpenRouter's half-price promotion as the directory carries it.
    static let halfOff = RouterModelPromotion(label: "50% off", discountBasisPoints: 5_000, endsAt: nil)

    /// The text with the combining long stroke overlay after every character
    /// — the strikethrough a macOS menu subtitle can actually draw.
    static func struck(_ text: String) -> String {
        text.map { "\($0)\u{0336}" }.joined()
    }
}

@Suite("Source link page anchor")
struct SourceLinkPageAnchorTests {
    @Test("A positive whole number is a page; anything else is none")
    func pageValues() {
        #expect(SourceLinkPageAnchor.page(from: "7") == 7)
        #expect(SourceLinkPageAnchor.page(from: " 12 ") == 12)
        #expect(SourceLinkPageAnchor.page(from: "0") == nil)
        #expect(SourceLinkPageAnchor.page(from: "-3") == nil)
        #expect(SourceLinkPageAnchor.page(from: "7.5") == nil)
        #expect(SourceLinkPageAnchor.page(from: "p7") == nil)
        #expect(SourceLinkPageAnchor.page(from: "") == nil)
        #expect(SourceLinkPageAnchor.page(from: nil) == nil)
    }

    @Test("A citation link carries its page beside the excerpt, and a plain link carries none")
    func linkCarriesPage() throws {
        let paged = try #require(URL(string: "foreverlm://source/src_abc?page=7&q=the+large+negative+value"))
        let link = try #require(ChatMarkdownView.sourceLink(from: paged))
        #expect(link.sourceID == "src_abc")
        #expect(link.page == 7)
        #expect(link.passage == "the large negative value")
        #expect(link.seconds == nil)

        let plain = try #require(URL(string: "foreverlm://source/src_abc"))
        #expect(ChatMarkdownView.sourceLink(from: plain)?.page == nil)

        let timed = try #require(URL(string: "foreverlm://source/src_abc?t=754"))
        let timedLink = try #require(ChatMarkdownView.sourceLink(from: timed))
        #expect(timedLink.seconds == 754)
        #expect(timedLink.page == nil)
    }

    @Test("A PDF's form feeds become numbered page lines for the model; text without them is untouched")
    func pageMarkers() {
        let stored = "First page text.\u{000C}812 Chapter 14\nSecond page text.\u{000C}Third."
        let labeled = PDFPageMarkers.labeled(stored)
        #expect(labeled == "[page 1]\n\nFirst page text.\n\n[page 2]\n\n812 Chapter 14\nSecond page text.\n\n[page 3]\n\nThird.")
        #expect(!labeled.contains("\u{000C}"))

        let article = "No pages here.\n\nJust paragraphs."
        #expect(PDFPageMarkers.labeled(article) == article)
    }

    @Test("A reader passage target may name only a page")
    @MainActor
    func pageOnlyTarget() {
        let vm = StudioViewModel(storageService: StorageService(storeRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("PageAnchor_\(UUID().uuidString)")))
        vm.requestReaderPassage(nil, page: 4, for: "src_x")
        #expect(vm.readerPassageTarget?.passage == nil)
        #expect(vm.readerPassageTarget?.page == 4)

        vm.requestReaderPassage("  ", page: 0, for: "src_y")
        #expect(vm.readerPassageTarget?.sourceID == "src_x")

        vm.requestReaderPassage("some words", page: 9, for: "src_z")
        #expect(vm.readerPassageTarget?.passage == "some words")
        #expect(vm.readerPassageTarget?.page == 9)
    }
}

@Suite("Model picker opens upward")
struct UpwardMenuAnchorTests {
    /// The composer sits at the foot of the chat, so the model menu's bottom
    /// edge goes just above the chip: in a flipped view (y grows down) the
    /// menu's top-left is its height plus the gap above the chip's top.
    @Test("The menu's top-left puts its bottom edge just above the chip")
    func menuEndsAboveTheChip() {
        let chip = NSRect(x: 0, y: 0, width: 120, height: 24)
        let gap = UpwardMenuAnchor.gap
        let flipped = UpwardMenuAnchor.origin(in: chip, isFlipped: true, menuHeight: 342)
        #expect(flipped == NSPoint(x: 0, y: -(gap + 342)))
        let unflipped = UpwardMenuAnchor.origin(in: chip, isFlipped: false, menuHeight: 342)
        #expect(unflipped == NSPoint(x: 0, y: 24 + gap + 342))
    }

    @Test("A press of the picker's key opens one chip's menu, however many chats are listening")
    @MainActor
    func oneChipClaimsAKeyPress() {
        let press = UUID()
        #expect(UpwardMenuAnchor.claim(press))
        #expect(!UpwardMenuAnchor.claim(press))
        #expect(UpwardMenuAnchor.claim(UUID()))
    }
}

/// The model chip leads with Recent models, as Codex's picker does.
@Suite("Recent chat models")
struct ChatRecentModelsTests {
    typealias Entry = ChatRecentModels.Entry

    @Test("A pick goes to the head, replaces its model's older row, and the list stays short")
    func newestFirstOnePerModel() {
        let a = Entry(provider: "openRouter", model: "lab/a", effort: "high")
        let b = Entry(provider: "openRouter", model: "lab/b", effort: nil)
        var list = ChatRecentModels.adding(a, to: [])
        list = ChatRecentModels.adding(b, to: list)
        #expect(list == [b, a])
        let aLow = Entry(provider: "openRouter", model: "lab/a", effort: "low")
        list = ChatRecentModels.adding(aLow, to: list)
        #expect(list == [aLow, b])
        for index in 0..<10 {
            list = ChatRecentModels.adding(Entry(provider: "openRouter", model: "lab/m\(index)", effort: nil), to: list)
        }
        #expect(list.count == ChatRecentModels.limit)
        #expect(list.first?.model == "lab/m9")
    }

    @Test("Recorded picks survive a relaunch in this Mac's defaults")
    func recordsAndLoads() throws {
        let suite = "ChatRecentModelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ChatRecentModels.load(defaults: defaults).isEmpty)
        let entry = Entry(provider: "openRouter", model: "lab/a", effort: "medium")
        ChatRecentModels.record(entry, defaults: defaults)
        ChatRecentModels.record(Entry(provider: "openRouter", model: "lab/b", effort: nil), defaults: defaults)
        #expect(ChatRecentModels.load(defaults: defaults).map(\.model) == ["lab/b", "lab/a"])
        defaults.set(Data("not json".utf8), forKey: ChatRecentModels.defaultsKey)
        #expect(ChatRecentModels.load(defaults: defaults).isEmpty)
    }
}

/// 2026-09-25: a chat asked to add one compound to a Site called save_site,
/// publish_site and read_site_file some sixty times, each refused with the
/// same sentence, and every refused row read "Saved site".
@Suite("Repeated tool refusals")
struct RepeatedToolRefusalTests {
    typealias Refusals = ReviewSessionManager.RepeatedToolRefusals
    typealias Result = ReviewSessionManager.AppToolResult

    @Test("A failed row says it failed, in the tool's own words")
    @MainActor
    func failedRowsSayTheyFailed() {
        var activity = ReviewSessionManager.Message.ToolActivity(
            toolName: "save_site", detail: nil, state: .succeeded, resultPreview: nil
        )
        #expect(activity.title == "Saved site")
        activity.state = .running
        #expect(activity.title == "Saved site")
        activity.state = .failed
        #expect(activity.title == "Couldn't save site")
        typealias Activity = ReviewSessionManager.Message.ToolActivity
        #expect(Activity.failedTitle(fromDoneTitle: "Read site file") == "Couldn't read site file")
        #expect(Activity.failedTitle(fromDoneTitle: "Wrote walkthrough") == "Couldn't write walkthrough")
        #expect(Activity.failedTitle(fromDoneTitle: "Opened in Browser") == "Couldn't open in Browser")
        #expect(Activity.failedTitle(fromDoneTitle: "Clicked") == "Couldn't click")
        #expect(Activity.failedTitle(fromDoneTitle: "some_new_tool") == "some_new_tool failed")
    }

    @Test("The third identical refusal tells the model to stop, whichever tool gave it")
    @MainActor
    func thirdRefusalStops() {
        var refusals = Refusals()
        let refusal = "Error: ‘Atlas’ has no file companies.html. Its files: index.html."
        #expect(refusals.record(toolName: "save_site", result: Result(text: refusal, isError: true)) == refusal)
        let respaced = "error:  ‘atlas’ has no file companies.html. its files: index.html."
        #expect(refusals.record(toolName: "read_site_file", result: Result(text: respaced, isError: true)) == respaced)
        #expect(refusals.withheldResult(for: "save_site") == nil, "two refusals are not yet a loop")
        let third = refusals.record(toolName: "replace_site_text", result: Result(text: refusal, isError: true))
        #expect(third.hasPrefix(refusal))
        #expect(third.contains("read_site_file, replace_site_text, save_site will not be run again"), "case and spacing did not make the second a new refusal")

        // Every tool that gave it is withheld; others still run.
        let withheld = refusals.withheldResult(for: "read_site_file")
        #expect(withheld?.isError == true)
        #expect(withheld?.text.contains("‘Atlas’ has no file") == true)
        #expect(refusals.withheldResult(for: "list_docs") == nil)
        #expect(refusals.exhaustedRefusal == nil)
        _ = refusals.withheldResult(for: "save_site")
        _ = refusals.withheldResult(for: "replace_site_text")
        #expect(refusals.exhaustedRefusal?.hasPrefix("‘Atlas’ has no file") == true, "three withheld calls end the turn")
    }

    @Test("Successes and different refusals do not count toward a stop")
    @MainActor
    func differentRefusalsDoNotStop() {
        var refusals = Refusals()
        for handle in ["atlas", "mitochondria", "3a7be032"] {
            let text = "No site of yours is named \(handle)."
            #expect(refusals.record(toolName: "save_site", result: Result(text: text, isError: true)) == text)
        }
        for _ in 0..<5 {
            _ = refusals.record(toolName: "list_docs", result: Result(text: "[]", isError: false))
        }
        #expect(refusals.withheldResult(for: "save_site") == nil)
        #expect(refusals.withheldResult(for: "list_docs") == nil)
        #expect(refusals.exhaustedRefusal == nil)
    }

    @Test("The stop is not read as the provider rejecting native tools")
    @MainActor
    func stopIsNotANativeToolRejection() {
        let stop = Refusals.Stopped(refusal: "ForeverLM app tools are not available in this Chat surface.")
        #expect(!AINativeToolSupport.isNativeToolRejection(stop))
        #expect(stop.localizedDescription.contains("kept retrying a tool that refused the same way"))
    }
}

/// Stop ends a turn at once whatever the turn is waiting on (2026-09-27: Stop
/// in a quiz's chat did nothing for two minutes). Nothing here is timed: the
/// stand-in tool runs until the test lets it go, so a wait that ended while it
/// still ran ended without it.
@Suite("Chat Stop ends the wait")
@MainActor
struct ChatStopEndsTheWaitTests {
    /// A tool that takes no notice of cancellation: it says when it has
    /// started, then runs until `release`, cancelled or not.
    private final class StubbornTool: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        var isReleased: Bool { lock.withLock { released } }

        func run() async {
            let starters: [CheckedContinuation<Void, Never>] = lock.withLock {
                started = true
                defer { startWaiters = [] }
                return startWaiters
            }
            starters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                let now: Bool = lock.withLock {
                    if released { return true }
                    releaseWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func untilStarted() async {
            await withCheckedContinuation { continuation in
                let now: Bool = lock.withLock {
                    if started { return true }
                    startWaiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func release() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                defer { releaseWaiters = [] }
                return releaseWaiters
            }
            waiting.forEach { $0.resume() }
        }
    }

    /// Lets the tool go after a while, so a wait that never ends fails the
    /// test instead of hanging the run.
    private func releasing(_ tool: StubbornTool) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            tool.release()
        }
    }

    @Test("Stop ends an app tool call whose tool takes no notice of it")
    func stopEndsAStubbornToolCall() async {
        let tool = StubbornTool()
        let safety = releasing(tool)
        defer { safety.cancel(); tool.release() }
        let call = Task { @MainActor in
            try await ReviewSessionManager.runAppToolCall(
                name: "import_paper_from_url",
                arguments: ["url": "https://example.org/paper"],
                hostSessionID: "chat-1",
                watchdogSeconds: 300
            ) { _, _, _ in
                await tool.run()
                return ReviewSessionManager.AppToolResult(text: "imported", isError: false)
            }
        }
        await tool.untilStarted()
        call.cancel()
        let result = await call.result
        #expect(!tool.isReleased, "the wait lasted as long as the tool")
        guard case .failure(let error) = result else {
            Issue.record("a stopped call returned \(result)")
            return
        }
        #expect(error is CancellationError)
    }

    @Test("The watchdog gives up on a tool that runs past it, without waiting for it")
    func watchdogAbandonsAStubbornTool() async throws {
        let tool = StubbornTool()
        let safety = releasing(tool)
        defer { safety.cancel(); tool.release() }
        let result = try await ReviewSessionManager.runAppToolCall(
            name: "transcribe_meeting_recording",
            arguments: [:],
            hostSessionID: nil,
            watchdogSeconds: 0.2
        ) { _, _, _ in
            await tool.run()
            return ReviewSessionManager.AppToolResult(text: "transcribed", isError: false)
        }
        #expect(!tool.isReleased, "the watchdog waited for the tool")
        #expect(result.isError)
        #expect(result.text.contains("transcribe_meeting_recording tool call timed out"))
    }

    @Test("A tool that answers in time is answered, with the chat's arguments")
    func toolThatAnswersIsAnswered() async throws {
        let result = try await ReviewSessionManager.runAppToolCall(
            name: "list_sources",
            arguments: ["limit": 3],
            hostSessionID: "chat-2",
            watchdogSeconds: 300
        ) { name, arguments, session in
            ReviewSessionManager.AppToolResult(
                text: "\(name) \(arguments["limit"] as? Int ?? 0) \(session ?? "-")",
                isError: false
            )
        }
        #expect(result.text == "list_sources 3 chat-2")
        #expect(!result.isError)
    }

    @Test("Work a stopped caller left behind is cancelled, and a caller stopped before it waits never waits")
    func abandonedWorkIsCancelled() async {
        let tool = StubbornTool()
        let safety = releasing(tool)
        defer { safety.cancel(); tool.release() }
        let sawCancel = AsyncStream<Bool>.makeStream()
        let call = Task {
            try await CancellableWait.run {
                await tool.run()
                sawCancel.continuation.yield(Task.isCancelled)
                sawCancel.continuation.finish()
                return "done"
            }
        }
        await tool.untilStarted()
        call.cancel()
        _ = await call.result
        #expect(!tool.isReleased)
        tool.release()
        var iterator = sawCancel.stream.makeAsyncIterator()
        let workSawCancel = await iterator.next()
        #expect(workSawCancel == true)

        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CancellableWait.run { "never needed" }
        }
        guard case .failure(let error) = await early.result else {
            Issue.record("an already-stopped caller waited")
            return
        }
        #expect(error is CancellationError)
    }
}

/// Every Claude since 4.6 refuses a request that ends on the assistant's own
/// words ("does not support assistant message prefill", 400), and a request may
/// be served by another model than the one it names, so no request ends there.
@Suite("Requests end on a turn the model answers")
struct ChatRequestTurnOrderTests {
    @Test("A closing assistant message is answered with a user turn")
    func closingAssistantMessageGetsAUserTurn() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "You tutor."],
            ["role": "user", "content": "What do cristae do?"],
            ["role": "assistant", "content": "They fold the inner membrane"],
        ]
        let sent = ChatRequestTurnOrder.endingOnAnswerableTurn(messages)
        #expect(sent.count == 4)
        #expect(sent.last?["role"] as? String == "user")
        #expect(sent.last?["content"] as? String == ChatRequestTurnOrder.continueInstruction)
    }

    @Test("A trailing system message does not hide a closing assistant message")
    func trailingSystemMessageIsSkipped() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Grade me."],
            ["role": "assistant", "content": "Graded."],
            ["role": "system", "content": "Ask the next question."],
        ]
        let sent = ChatRequestTurnOrder.endingOnAnswerableTurn(messages)
        #expect(sent.last?["role"] as? String == "user")
    }

    @Test("A request that already ends on the learner or a tool is sent as it is")
    func answerableEndingsAreUntouched() {
        let user: [[String: Any]] = [["role": "user", "content": "Hello"]]
        #expect(ChatRequestTurnOrder.endingOnAnswerableTurn(user).count == 1)
        let toolRound: [[String: Any]] = [
            ["role": "user", "content": "Find it."],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function"]]],
            ["role": "tool", "tool_call_id": "c1", "content": "found"],
        ]
        #expect(ChatRequestTurnOrder.endingOnAnswerableTurn(toolRound).count == 3)
        let pendingCalls: [[String: Any]] = [
            ["role": "user", "content": "Find it."],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function"]]],
        ]
        #expect(ChatRequestTurnOrder.endingOnAnswerableTurn(pendingCalls).count == 2)
    }

    @Test("Every Mac OpenRouter body ends on a user turn")
    func macOpenRouterBodyEndsOnAUserTurn() {
        var payload: [String: Any] = [
            "model": "anthropic/claude-opus-5.5",
            "messages": [
                ["role": "system", "content": "You tutor."],
                ["role": "user", "content": "Quiz me."],
                ["role": "assistant", "content": "Here is your next question"],
            ] as [[String: Any]],
        ]
        AIService.applyOpenRouterPayloadExtras(&payload, provider: .openRouter)
        let messages = payload["messages"] as? [[String: Any]] ?? []
        #expect(messages.last?["role"] as? String == "user")
    }

    @Test("The phone's OpenRouter body ends on a user turn")
    func phoneOpenRouterBodyEndsOnAUserTurn() throws {
        let route = ResolvedAITextRoute(task: .chat, provider: "OpenRouter", model: "anthropic/claude-opus-5.5")
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: "You tutor.",
            messages: [
                (role: "assistant", content: "What do cristae do?"),
                (role: "user", content: "They fold the membrane."),
                (role: "assistant", content: "Right."),
            ],
            maxTokens: 256
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.last?["role"] as? String == "user")
    }

    @Test("Retry leaves the failed attempt's words out of the request")
    @MainActor func retryLeavesTheFailedAttemptOut() {
        typealias Message = ReviewSessionManager.Message
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var cutOff = Message(role: .assistant, content: "Mitochondrial uncouplers work by", createdAt: start.addingTimeInterval(4))
        cutOff.isFromFailedAttempt = true
        let history = [
            Message(role: .user, content: "Explain uncouplers.", createdAt: start),
            cutOff,
        ]
        let sent = ReviewSessionManager.providerMessagesForTesting(from: history)
        #expect(sent.map(\.role) == ["user"])
    }

    @Test("A safety decline says the model declined, not that the provider stopped")
    func safetyDeclineIsNamed() {
        for reason in ["refusal", "content_filter"] {
            do {
                try AICompletionStopValidator.throwIfStoppedAbnormally(["finish_reason": reason])
                Issue.record("\(reason) passed as a normal stop")
            } catch {
                #expect(error.localizedDescription.contains("declined"))
            }
        }
    }
}

// MARK: - One-page transcript

@Suite("One-page chat transcript")
struct ChatTranscriptPageTests {
    private static func search(_ state: ReviewSessionManager.Message.ToolActivity.State = .succeeded)
        -> ReviewSessionManager.Message.ToolActivity {
        ReviewSessionManager.Message.ToolActivity(
            toolName: "search_sources_semantic", detail: "q", state: state, resultPreview: "Line one"
        )
    }

    private static let thinking = ReviewSessionManager.Message.ToolActivity(
        kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
        resultPreview: nil, reasoning: "First thought.\n\nSecond thought.", thinkingDuration: 8
    )

    @MainActor
    private static func plainChat(extraStep: ReviewSessionManager.Message.ToolActivity? = nil) -> [ReviewSessionManager.Message] {
        var messages = [
            ReviewSessionManager.Message(role: .user, content: "What did the meeting conclude?"),
            ReviewSessionManager.Message(role: .assistant, content: "", toolActivity: thinking),
            ReviewSessionManager.Message(role: .tool, content: "", toolActivity: search()),
        ]
        if let extraStep {
            messages.append(ReviewSessionManager.Message(role: .tool, content: "", toolActivity: extraStep))
        }
        messages.append(ReviewSessionManager.Message(role: .assistant, content: "## The question\n\nIt stayed open."))
        return messages
    }

    @Test("A question with a picture shows the picture over its words, and the words alone in the bubble")
    @MainActor
    func attachedPicturesRideAboveTheWords() throws {
        let picture = "foreverlm://image/attached/0F1E2D3C-4B5A-4C6D-8E7F-0A1B2C3D4E5F"
        let message = ReviewSessionManager.Message(role: .user, content: "What is this?\n\n![figure](\(picture))")
        let blocks = ReviewChatTranscriptBlock.grouping([message])
        let user = ChatTranscriptPage.userBlock(blocks[0], message: try #require(blocks.first?.userMessage), canEdit: false, isFindMatch: false)
        #expect(user.text == "What is this?")
        #expect(user.images?.contains(picture) == true)

        // A message that was only the picture has no bubble.
        let only = ReviewSessionManager.Message(role: .user, content: "![figure](\(picture))")
        let onlyBlocks = ReviewChatTranscriptBlock.grouping([only])
        let pictureOnly = ChatTranscriptPage.userBlock(onlyBlocks[0], message: only, canEdit: false, isFindMatch: false)
        #expect(pictureOnly.text == nil)
        #expect(pictureOnly.images != nil)
    }

    @Test("A browser step's picture and a missing plugin ride the reply's steps")
    @MainActor
    func workCarriesBrowserPreviewAndSetup() {
        var browser = ReviewSessionManager.Message.ToolActivity(
            toolName: "browser_open", detail: "https://example.com", state: .succeeded, resultPreview: nil
        )
        browser.previewImage = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let work = ReviewChatWork(
            id: UUID(),
            steps: [Self.search(), browser],
            pages: [ChatWrittenPage(id: "page-1", title: "Notes")],
            duration: 12,
            answerHasBegun: true
        )
        let part = ChatTranscriptPage.workPart(work, isLive: false) { page in "Now: \(page.title)" }
        #expect(part.previewStep == 1)
        #expect(part.preview?.hasPrefix("data:image/png;base64,") == true)
        #expect(part.pages == [ChatTranscriptPage.PageCard(id: "page-1", title: "Now: Notes")])
        #expect(part.setup == nil)
    }

    @Test("Sources added before a message read as one line that opens onto their names")
    @MainActor
    func addedSourcesSummarise() {
        #expect(ChatTranscriptPage.added([]) == nil)
        let added = ChatTranscriptPage.added([
            ChatContextAdditions.Source(id: "a", title: "", type: "article"),
        ])
        #expect(added?.sources.first?.title == "Untitled source")
    }

    @Test("A reply becomes its steps and its prose, a question its words")
    @MainActor
    func blocksCarryWhatTheNativeRowsShow() throws {
        let messages = Self.plainChat()
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        #expect(blocks.count == 2)
        let question = try #require(blocks.first?.userMessage)
        let user = ChatTranscriptPage.userBlock(blocks[0], message: question, canEdit: true, isFindMatch: false)
        #expect(user.kind == .user)
        #expect(user.text == "What did the meeting conclude?")
        #expect(user.canEdit == true)
        #expect(user.collapses == nil)

        let items = ReviewChatAnswerLayout.items(blocks[1].answerMessages)
        guard case .work(let work) = items.first, case .entry(let entry) = items.last,
              let reply = entry.message else {
            Issue.record("expected the steps, then the reply")
            return
        }
        let settled = ChatTranscriptPage.workPart(work, isLive: false)
        #expect(settled.kind == .work)
        #expect(settled.settled == true)
        #expect(settled.opensWhileLive == false)
        #expect(settled.steps?.map(\.kind) == ["thinking", "tool"])
        #expect(settled.steps?.first?.paragraphs == ["First thought.", "Second thought."])
        #expect(settled.steps?.last?.summary == "1 line of output")

        let working = ChatTranscriptPage.workPart(work, isLive: true)
        // The answer has begun under these steps, so they are done even live.
        #expect(working.title == settled.title)

        let prose = try #require(ChatTranscriptPage.prosePart(reply, citations: .init()))
        #expect(prose.markdown == "## The question\n\nIt stayed open.")
        #expect(prose.citations == nil)
        #expect(prose.webSources == nil)
    }

    @Test("A long paste folds on the page as it does in the native bubble")
    @MainActor
    func longPasteFolds() throws {
        let paste = (1...40).map { "Line \($0) of a pasted log." }.joined(separator: "\n")
        let messages = [ReviewSessionManager.Message(role: .user, content: paste)]
        let blocks = ReviewChatTranscriptBlock.grouping(messages)
        let message = try #require(blocks.first?.userMessage)
        let user = ChatTranscriptPage.userBlock(blocks[0], message: message, canEdit: false, isFindMatch: true)
        #expect(user.collapses == true)
        #expect(user.canEdit == nil)
        #expect(user.isFindMatch == true)
    }
}

/// A provider that answered a chat with a 408 and then held the body open sent
/// the chat into eleven minutes of "Thinking" (2026-11-08): URLSession hands
/// over no response until its first body byte, and the AI session has no idle
/// deadline. A stream now fails as timed out when nothing arrives in time, and
/// an error body that never ends is reported by its status.
@Suite("A stream that stalls", .serialized)
struct StalledErrorBodyStreamTests {
    @Test("A stream that sends nothing fails as a retryable timeout once the first-byte limit runs out", .timeLimit(.minutes(1)))
    func silentStreamTimesOut() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .nothing)
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        let request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)

        let started = ContinuousClock.now
        let error = await #expect(throws: AIError.self) {
            try await service.streamSSE(
                request: request,
                firstByteLimit: .milliseconds(200),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        guard case .apiError(let message)? = error else {
            Issue.record("Expected a timeout, got \(String(describing: error))")
            return
        }
        #expect(message.contains("timed out"))
        // The chat retries a timeout; that is what ends the endless "Thinking".
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError(message)))
        // The held request was cancelled, not left open on the connection.
        try await StalledErrorBodyURLProtocol.waitUntilStopped()
    }

    @Test("Stopping a stream that has sent nothing reads as a stop, not a timeout", .timeLimit(.minutes(1)))
    func stoppingASilentStreamIsNotATimeout() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .nothing)
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        let request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)

        let turn = Task {
            try await service.streamSSE(
                request: request,
                firstByteLimit: .seconds(30),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
        }
        try await StalledErrorBodyURLProtocol.waitUntilStarted()
        turn.cancel()
        do {
            try await turn.value
            Issue.record("A stopped stream returned as if it had answered")
        } catch {
            #expect(!error.localizedDescription.contains("timed out"))
        }
    }

    @Test("A 408 whose body never ends fails with its status once the read limit runs out", .timeLimit(.minutes(1)))
    func stalledErrorBodyFailsWithItsStatus() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .heldBody)
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        var request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)
        request.httpMethod = "POST"

        let started = ContinuousClock.now
        do {
            try await service.streamSSE(
                request: request,
                errorBodyReadLimit: .milliseconds(200),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
            Issue.record("A 408 stream returned as if it had answered")
        } catch let error as AIError {
            guard case .httpError(let status, let message, _) = error else {
                Issue.record("Expected the HTTP status, got \(error)")
                return
            }
            #expect(status == 408)
            #expect(message.contains("(408)"))
            // A 408 is retried, which is the whole point of failing promptly.
            #expect(AITransientErrorClassifier.isTransient(error))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        // The held request was cancelled, not left open on the connection.
        try await StalledErrorBodyURLProtocol.waitUntilStopped()
    }

    @Test("An error body that arrives in time is still read as the provider's message", .timeLimit(.minutes(1)))
    func finishedErrorBodyKeepsTheProvidersMessage() async throws {
        StalledErrorBodyURLProtocol.reset(reply: .body(#"{"error":{"message":"Upstream model took too long"}}"#))
        let service = AIService(session: StalledErrorBodyURLProtocol.mockSession())
        let request = URLRequest(url: URL(string: "https://router.example.test/v1/chat/completions")!)

        let error = await #expect(throws: AIError.self) {
            try await service.streamSSE(
                request: request,
                errorBodyReadLimit: .seconds(5),
                onEvent: { _ in nil },
                onDelta: { _ in }
            )
        }
        guard case .httpError(let status, let message, _)? = error else {
            Issue.record("Expected the HTTP status, got \(String(describing: error))")
            return
        }
        #expect(status == 408)
        #expect(message.contains("Upstream model took too long"))
    }
}

/// Stands in for a provider that stalls: it says nothing at all, or answers
/// with a 408 whose body it holds open, or a 408 with a body it finishes.
private final class StalledErrorBodyURLProtocol: URLProtocol {
    enum Reply {
        case nothing
        case heldBody
        case body(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply.nothing
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var stopped = 0

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StalledErrorBodyURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0
        return URLSession(configuration: configuration)
    }

    static func reset(reply: Reply) {
        lock.withLock { self.reply = reply; started = 0; stopped = 0 }
    }

    static func waitUntilStarted() async throws {
        while lock.withLock({ started }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func waitUntilStopped() async throws {
        while lock.withLock({ stopped }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.started += 1
            return Self.reply
        }
        if case .nothing = reply { return }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 408, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard case .body(let body) = reply else { return }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stopped += 1 }
    }
}
