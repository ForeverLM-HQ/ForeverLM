import Foundation
import Testing
@testable import ForeverLM

@Suite("Mobile Reader Text")
struct MobileReaderTextTests {
    @Test("Decodes current CloudKit source-text assets before legacy payload text")
    func decodesSourceTextAsset() throws {
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSourceTextAsset_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: assetURL) }
        try Data("Canonical synced paper text.".utf8).write(to: assetURL)
        let legacyPayload = try JSONSerialization.data(withJSONObject: [
            "article": ["content": "Legacy embedded text."],
        ])

        #expect(MobileSourceTextDecoder.text(
            assetURL: assetURL,
            payloadData: legacyPayload
        ) == "Canonical synced paper text.")
    }

    @Test("Falls back to readable legacy payload text")
    func decodesLegacyPayloadText() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "article": ["content": "Legacy article text."],
        ])

        #expect(MobileSourceTextDecoder.text(
            assetURL: nil,
            payloadData: payload
        ) == "Legacy article text.")
    }

    @Test("Rejects missing and whitespace-only source text")
    func rejectsUnreadableSourceText() throws {
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSourceTextWhitespace_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: assetURL) }
        try Data("  \n\t".utf8).write(to: assetURL)
        let payload = try JSONSerialization.data(withJSONObject: [
            "article": ["content": "  \n"],
        ])

        #expect(MobileSourceTextDecoder.text(assetURL: assetURL, payloadData: payload) == nil)
        #expect(MobileSourceTextDecoder.text(assetURL: nil, payloadData: Data("not json".utf8)) == nil)
    }

    @Test("Preserves back matter in the main reading text")
    func preservesBackMatter() throws {
        let chapter = Array(
            repeating: "The chapter explains why progress is possible and what the reader can do next.",
            count: 12
        ).joined(separator: "\n")
        let raw = """
        13. Reasons for Hope
        \(chapter)
        Glossary
        Aging is the gradual accumulation of damage.
        Additional Resources
        A long list of websites and books follows.
        """

        let reflowed = MobileReaderText.reflowed(raw, sourceType: "book")
        let sections = MobileReaderText.readingSections(
            in: reflowed,
            sourceType: "book",
            sourceTitle: "13) Reasons for Hope"
        )

        #expect(sections.main.contains("what the reader can do next"))
        #expect(sections.main.contains("Glossary"))
        #expect(sections.main.contains("Additional Resources"))
        #expect(sections.supplementary == nil)
    }

    @Test("Preserves repeated article cards")
    func preservesRepeatedRecommendationCards() {
        let article = Array(
            repeating: "This is substantive article prose that belongs in the uninterrupted reading view.",
            count: 20
        ).joined(separator: " ")
        let raw = """
        \(article)

        Emerging Technology

        Article

        First unrelated story

        read more

        Emerging Technology

        Policy Statement

        Second unrelated story

        read more

        Emerging Technology

        Article

        Third unrelated story

        read more
        """

        let sections = MobileReaderText.readingSections(
            in: raw,
            sourceType: "article",
            sourceTitle: "A substantive article"
        )

        #expect(sections.main.contains("substantive article prose"))
        #expect(sections.main.contains("First unrelated story"))
        #expect(sections.supplementary == nil)
    }

    @Test("Preserves trailing footnotes")
    func preservesTrailingFootnotes() {
        let article = Array(
            repeating: "The article develops its argument with enough detail to form the primary reading experience.",
            count: 18
        ).joined(separator: " ")
        let raw = """
        \(article)

        Conclusion

        The conclusion completes the article's argument.

        1

        First explanatory footnote.

        2

        Second explanatory footnote.

        3

        Third explanatory footnote.
        """

        let sections = MobileReaderText.readingSections(
            in: raw,
            sourceType: "article",
            sourceTitle: "An article with notes"
        )

        #expect(sections.main.contains("completes the article's argument"))
        #expect(sections.main.contains("First explanatory footnote"))
        #expect(sections.supplementary == nil)
    }

    @Test("Renders structure while escaping untrusted source text")
    func rendersStructuredSafeHTML() {
        let html = MobileReaderText.html(
            body: "## Results\n\n- First\n- Second\n\nA value^(12) <script>alert(1)</script>",
            sourceType: "article",
            sourceTitle: "Results",
            fontScale: 1,
            truncated: false
        )

        #expect(html.contains("<h2>Results</h2>"))
        #expect(html.contains("<ul><li>First</li><li>Second</li></ul>"))
        #expect(html.contains("A value<sup>12</sup> &lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<script>alert(1)</script>"))
    }

    @Test("Keeps prose after a heading in body styling without a blank line")
    func separatesHeadingFromFollowingProse() {
        let html = MobileReaderText.html(
            body: "# Twenty Years in Biotech\nIn the blink of an eye, twenty years have passed.\nThe work continued.",
            sourceType: "article",
            sourceTitle: "Twenty Years in Biotech",
            fontScale: 1,
            truncated: false
        )

        #expect(html.contains("<h1>Twenty Years in Biotech</h1>"))
        #expect(html.contains("<p>In the blink of an eye, twenty years have passed. The work continued.</p>"))
        #expect(!html.contains("<h1>Twenty Years in Biotech In the blink"))
    }
}

/// A podcast's stored transcript carries the speaker labels ForeverLM's own import
/// wrote — `[SPEAKER_2]` above a turn from the TTML extractor, `**Name:**` at a
/// paragraph head from the formatting pass — and the phone used to print them as
/// text. The reader now lays the conversation out as turns.
@Suite("Mobile Transcript Text")
struct MobileTranscriptTextTests {
    /// The extractor's shape, with the AI-inferred names the Mac wrote back.
    private static let bracketTranscript = """
    [Andrea Hiott]
    Hello, everyone. Welcome to Love and Philosophy.

    [Philip Ball]
    Thanks for having me.

    [Andrea Hiott]
    Let me tell you a little bit about this book

    . It comes at a moment when biology is shifting.

    [Philip Ball]
    That is exactly the argument.

    [Andrea Hiott]
    Say more.
    """

    /// A real stored episode: the formatting pass layered bold labels onto the
    /// extractor's bracket labels, most of them standing on empty lines, and one
    /// contradicting the bracket label that actually carries the words.
    private static let layeredTranscript = """
    [SPEAKER_1]
    Tell me, Nick, what is life?

    **SPEAKER_2:** 

    [SPEAKER_2]
    Ah, well, I can't tell you.

    [SPEAKER_1]
    Seems like it might be easier to answer the question, what is death?

    **SPEAKER_1:** 

    [SPEAKER_2]
    Death is really easy. You lose your membrane potential permanently.

    [SPEAKER_2]
    We are burning rocket fuel.

    **Speaker 1:** Nick Lane, thank you for joining us.
    """

    private func html(_ body: String, sourceType: String = "podcast") -> String {
        MobileReaderText.html(
            body: body,
            sourceType: sourceType,
            sourceTitle: "Episode",
            fontScale: 1,
            truncated: false
        )
    }

    @Test("Bracket labels above each turn become speaker sections")
    func parsesBracketLabels() throws {
        let transcript = try #require(MobileTranscriptText.parse(Self.bracketTranscript))

        #expect(transcript.showsSpeakers)
        #expect(transcript.speakerIDs == ["ANDREA_HIOTT", "PHILIP_BALL"])
        #expect(transcript.blocks.count == 5)
        guard case .turn(let third) = transcript.blocks[2] else {
            Issue.record("Expected a turn"); return
        }
        #expect(third.speakerLabel == "Andrea Hiott")
        // A paragraph break inside a turn stays inside that speaker's turn.
        #expect(third.paragraphs == [
            "Let me tell you a little bit about this book",
            ". It comes at a moment when biology is shifting.",
        ])
    }

    @Test("Renders turns with the speaker's name and colour, never the raw label")
    func rendersSpeakerTurns() {
        let rendered = html(Self.bracketTranscript)

        #expect(rendered.contains(
            "<section class=\"flm-turn flm-accent-0\"><div class=\"flm-speaker\"><span class=\"flm-speaker-mark\"></span>Andrea Hiott</div><p>Hello, everyone. Welcome to Love and Philosophy.</p></section>"
        ))
        #expect(rendered.contains("flm-accent-1\"><div class=\"flm-speaker\"><span class=\"flm-speaker-mark\"></span>Philip Ball</div>"))
        #expect(!rendered.contains("[Andrea Hiott]"))
        #expect(!rendered.contains("<p>[Philip Ball]"))
    }

    @Test("Stray bold labels are dropped, and the label above the words wins")
    func reconcilesLayeredLabels() throws {
        let transcript = try #require(MobileTranscriptText.parse(Self.layeredTranscript))
        let turns = transcript.blocks.compactMap { block -> MobileTranscriptText.Turn? in
            if case .turn(let turn) = block { return turn }
            return nil
        }

        #expect(transcript.speakerIDs == ["SPEAKER_1", "SPEAKER_2"])
        #expect(turns.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 2", "Speaker 1"])
        // "**SPEAKER_1:**" on an empty line before "[SPEAKER_2]" did not steal the turn…
        #expect(turns[3].paragraphs == [
            "Death is really easy. You lose your membrane potential permanently.",
            "We are burning rocket fuel.",
        ])
        // …and "**Speaker 1:**" with its words on the same line is a turn.
        #expect(turns[4].paragraphs == ["Nick Lane, thank you for joining us."])

        let rendered = html(Self.layeredTranscript)
        #expect(!rendered.contains("**"))
        #expect(!rendered.contains("SPEAKER_"))
        #expect(rendered.contains(">Speaker 2</div>"))
    }

    @Test("A speaker keeps talking through paragraph breaks until a heading")
    func continuationAndHeadings() throws {
        let body = """
        # Episode 12

        **Host:** Welcome back to the show.

        Today we have a guest who studies sleep.

        **Guest:** Glad to be here.

        **Host:** Let's start with the basics.

        **Guest:** Sleep has stages.

        ## Show Notes

        - The lab's page
        - The paper we discussed

        [10:15] Sleep stages
        """
        let transcript = try #require(MobileTranscriptText.parse(body))

        #expect(transcript.blocks[0] == .plain("# Episode 12"))
        guard case .turn(let host) = transcript.blocks[1] else {
            Issue.record("Expected the host's turn"); return
        }
        #expect(host.paragraphs == [
            "Welcome back to the show.",
            "Today we have a guest who studies sleep.",
        ])
        // Show notes belong to nobody: heading, list and timestamp line stay plain.
        #expect(transcript.blocks.suffix(3) == [
            .plain("## Show Notes"),
            .plain("- The lab's page\n- The paper we discussed"),
            .plain("[10:15] Sleep stages"),
        ])

        let rendered = html(body)
        #expect(rendered.contains("<h1>Episode 12</h1>"))
        #expect(rendered.contains("<ul><li>The lab&#39;s page</li><li>The paper we discussed</li></ul>"))
        #expect(rendered.contains("<p>[10:15] Sleep stages</p>"))
    }

    @Test("One voice is a monologue: labels stripped, paragraphs kept")
    func singleVoiceDropsLabels() {
        let body = """
        [Andrew Huberman]
        Welcome to the podcast.

        [Andrew Huberman]
        Today we discuss dopamine.

        [Andrew Huberman]
        Let's begin.
        """
        let transcript = MobileTranscriptText.parse(body)

        #expect(transcript?.showsSpeakers == false)
        let rendered = html(body)
        #expect(!rendered.contains("class=\"flm-speaker\""))
        #expect(!rendered.contains("Andrew Huberman"))
        #expect(rendered.contains("<p>Welcome to the podcast.</p><p>Today we discuss dopamine.</p><p>Let&#39;s begin.</p>"))
    }

    @Test("Text without the app's labels is not a transcript")
    func rejectsUnlabeledText() {
        #expect(MobileTranscriptText.parse("""
        Tom Dayspring: Lipoproteins carry cholesterol.

        Peter Attia: Say more about ApoB.

        Note: this is a colon, not a label.
        """) == nil)
        #expect(MobileTranscriptText.parse("""
        [10:15]
        Sleep stages.

        [#2 listed above]
        A cross reference.

        [Music]
        Plays.
        """) == nil)
        // Two stray bracketed lines are not a conversation.
        #expect(MobileTranscriptText.parse("""
        [Music]
        Intro plays.

        [Applause]
        The crowd.
        """) == nil)
    }

    @Test("Only podcast sources take the transcript layout")
    func gatedBySourceType() {
        let rendered = html(Self.bracketTranscript, sourceType: "article")

        #expect(!rendered.contains("class=\"flm-turn"))
        #expect(rendered.contains("<p>[Andrea Hiott] Hello, everyone. Welcome to Love and Philosophy.</p>"))
    }

    @Test("A label written two ways is one speaker, and is escaped")
    func speakerIdentityAndEscaping() throws {
        #expect(MobileTranscriptText.speakerID(for: "Speaker 2") == "SPEAKER_2")
        #expect(MobileTranscriptText.speakerID(for: "SPEAKER_2") == "SPEAKER_2")
        #expect(MobileTranscriptText.speakerID(for: "José Núñez") == "JOSE_NUNEZ")
        #expect(MobileTranscriptText.displayLabel(for: "SPEAKER_12") == "Speaker 12")
        #expect(MobileTranscriptText.displayLabel(for: "Dwarkesh Patel") == "Dwarkesh Patel")

        let body = """
        [A <b>Host</b>]
        One.

        [Guest & Co]
        Two.

        **A <b>Host</b>:** Three.

        [Guest & Co]
        Four.
        """
        let transcript = try #require(MobileTranscriptText.parse(body))
        #expect(transcript.speakerIDs == ["A_B_HOST_B", "GUEST_CO"])
        let rendered = html(body)
        #expect(rendered.contains("A &lt;b&gt;Host&lt;/b&gt;</div>"))
        #expect(rendered.contains("Guest &amp; Co</div>"))
        #expect(!rendered.contains("<b>Host</b>"))
    }
}

/// The reader's second rendering path: a book chapter that synced as real markup
/// with its images inlined, rather than as text with every `<img>` stripped out.
@Suite("Mobile Reader Chapter Documents")
struct MobileReaderChapterDocumentTests {
    private static let inlineImage =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    @Test("Renders synced chapter markup instead of escaping it")
    func rendersChapterMarkup() {
        let html = MobileReaderText.documentHTML(
            bodyHTML: "<h2>Chapter Two</h2><p>An <em>emphasized</em> word.</p>",
            fontScale: 1,
            truncated: false
        )

        #expect(html.contains("<h2>Chapter Two</h2>"))
        #expect(html.contains("<em>emphasized</em>"))
        #expect(!html.contains("&lt;h2&gt;"))
    }

    @Test("Keeps inlined images, which are the whole point of the document")
    func keepsInlinedImages() {
        let html = MobileReaderText.documentHTML(
            bodyHTML: "<figure><img src=\"\(Self.inlineImage)\" alt=\"Plate 1\"/></figure>",
            fontScale: 1,
            truncated: false
        )

        #expect(html.contains(Self.inlineImage))
        #expect(html.contains("alt=\"Plate 1\""))
        // Publisher width rules assume a page; the reader clamps images to the column.
        #expect(html.contains("max-width: 100% !important"))
    }

    @Test("Lets a publisher's picture-drawn delta or arrow flow inline, on both readers")
    func inlineGlyphsFlowInline() {
        let html = MobileReaderText.documentHTML(
            bodyHTML: "<p><img src=\"\(Self.inlineImage)\" alt=\"Images\"/><i>G</i> = <img src=\"\(Self.inlineImage)\" alt=\"Images\"/><i>H</i></p>",
            fontScale: 1,
            truncated: false
        )
        // The phone's stylesheet exempts the class the script assigns…
        #expect(html.contains("img.\(ReaderInlineGlyphScript.className)"))
        #expect(ReaderInlineGlyphScript.source.contains("'\(ReaderInlineGlyphScript.className)'"))
        // …and so does the Mac's, which installs the same script.
        #expect(EPUBReaderStyles.css.contains("img.\(ReaderInlineGlyphScript.className)"))
        #expect(EPUBReaderStyles.injectionScript(theme: .system, extendedMediaNormalization: true)
            .contains("var GLYPH_CLASS = '\(ReaderInlineGlyphScript.className)'"))
    }

    @Test("Strips script, handlers and remote references from a chapter document")
    func sanitizesChapterMarkup() {
        let html = MobileReaderText.documentHTML(
            bodyHTML: """
            <script>fetch('https://example.com')</script>
            <p onclick="alert(1)">Text</p>
            <img src="https://tracker.example.com/pixel.png"/>
            <img src="\(Self.inlineImage)"/>
            <a href="javascript:alert(1)">Tap</a>
            """,
            fontScale: 1,
            truncated: false
        )

        #expect(!html.contains("fetch('https://example.com')"))
        #expect(!html.contains("onclick"))
        #expect(!html.contains("tracker.example.com"))
        #expect(!html.contains("javascript:alert(1)"))
        // Sanitizing must not take the inlined figures with it.
        #expect(html.contains(Self.inlineImage))
        #expect(html.contains("Text"))
    }

    @Test("Scales a chapter document's body font like the text reader")
    func scalesChapterFont() {
        let plain = MobileReaderText.html(
            body: "Paragraph.",
            sourceType: "book",
            sourceTitle: "Book",
            fontScale: 1.3,
            truncated: false
        )
        let chapter = MobileReaderText.documentHTML(
            bodyHTML: "<p>Paragraph.</p>",
            fontScale: 1.3,
            truncated: false
        )

        #expect(chapter.contains("--flm-body-size: 23.40px"))
        #expect(plain.contains("--flm-body-size: 23.40px"))
    }

    @Test("Carries the truncation notice like the text reader")
    func showsTruncationNotice() {
        let html = MobileReaderText.documentHTML(
            bodyHTML: "<p>Partial chapter.</p>",
            fontScale: 1,
            truncated: true
        )

        #expect(html.contains("flm-truncated"))
    }

    @Test("A protocol-relative image reference is treated as remote")
    func stripsProtocolRelativeReferences() {
        let html = MobileReaderText.documentHTML(
            bodyHTML: "<figure><img src=\"//cdn.example.com/a.png\"/><img src=\"\(Self.inlineImage)\"/></figure>",
            fontScale: 1,
            truncated: false
        )

        #expect(!html.contains("cdn.example.com"))
        #expect(html.contains(Self.inlineImage))
    }

    @Test("Sanitizer leaves ordinary prose untouched")
    func sanitizerPreservesProse() {
        let body = "<p>The word <strong>script</strong> appears in this sentence about javascript: prose.</p>"

        #expect(MobileReaderText.sanitizedBodyHTML(body) == body)
    }

    @Test("Sanitizer repairs mojibake in historical synced HTML")
    func sanitizerRepairsMojibake() {
        let body = "<p>Itâ€™s important, and weâ€™re ready.</p>"

        #expect(
            MobileReaderText.sanitizedBodyHTML(body)
                == "<p>It’s important, and we’re ready.</p>"
        )
    }
}

/// Which of the two book shapes a chapter is decides how the phone reads it: a
/// PDF-split chapter renders its own document, an EPUB chapter renders synced
/// markup. Getting this wrong shows a reader with no figures in it.
@Suite("Mobile Book Chapter Routing")
struct MobileBookChapterRoutingTests {
    private func source(sourceType: String, localFilePath: String?, url: String? = nil) -> MobileCloudSource {
        MobileCloudSource(
            id: "chapter-1",
            title: "Chapter One",
            subtitle: nil,
            sourceType: sourceType,
            dateAdded: .distantPast,
            hasAudio: false,
            isArchived: false,
            url: url,
            localFilePath: localFilePath
        )
    }

    @Test("A PDF-split chapter reads as its own document")
    func detectsPDFBackedChapter() {
        #expect(source(sourceType: "book", localFilePath: "Books/Deep Work/Chapters/03.pdf")
            .isPDFBackedBookChapter)
        #expect(source(
            sourceType: "book",
            localFilePath: "/Users/x/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/Books/Deep Work/Chapters/03.pdf"
        ).isPDFBackedBookChapter)
    }

    @Test("An EPUB chapter is not PDF-backed and reads synced markup")
    func epubChapterIsNotPDFBacked() {
        #expect(!source(sourceType: "book", localFilePath: "Books/Deep Work/Chapters/ch03.xhtml")
            .isPDFBackedBookChapter)
        #expect(!source(sourceType: "book", localFilePath: nil, url: "Books/Deep Work/Chapters/ch03.html")
            .isPDFBackedBookChapter)
    }

    @Test("Only book chapters can be PDF-backed chapters")
    func otherTypesAreUnaffected() {
        #expect(!source(sourceType: "paper", localFilePath: "Papers/attention.pdf").isPDFBackedBookChapter)
        #expect(!source(sourceType: "article", localFilePath: "Articles/saved.pdf").isPDFBackedBookChapter)
    }

    @Test("Archived articles take the rich reader document route")
    func archivedArticleRouting() {
        #expect(source(
            sourceType: "article",
            localFilePath: "Articles/saved/article.html"
        ).isArchivedArticle)
        #expect(source(
            sourceType: "article",
            localFilePath: "/Users/x/Library/Application Support/ForeverLM/Content/Articles/saved/article.HTML"
        ).isArchivedArticle)
        #expect(!source(
            sourceType: "article",
            localFilePath: "Downloads/article.html"
        ).isArchivedArticle)
    }
}
