import Foundation
import Testing
@testable import ForeverLM

@Suite("Canvas: Copy as Markdown")
struct KnowledgeMapMarkdownTests {
    private func node(
        _ ref: String,
        _ title: String,
        sub: String = "",
        detail: [String] = [],
        h: Double? = nil,
        quote: String? = nil,
        src: String? = nil
    ) -> KnowledgeMapNode {
        KnowledgeMapNode(
            ref: ref,
            kind: KnowledgeMapMarkdown.kind(of: ref),
            type: KnowledgeMapMarkdown.kind(of: ref),
            title: title,
            sub: sub,
            detail: detail,
            shore: "",
            h: h,
            quote: quote,
            src: src
        )
    }

    private let imageID = "ab12cd34-0000-4000-8000-0123456789ab"

    /// A canvas with a region inside a region, a card of every kind, and an arrow.
    private func sample() -> (layout: KnowledgeMapLayout, nodes: [String: KnowledgeMapNode]) {
        var layout = KnowledgeMapLayout()
        layout.setRegion("outer", .init(name: "Mitochondria", x: 0, y: 0, w: 1200, h: 800, color: "#D4537E", at: 1))
        layout.setRegion("inner", .init(name: "Membrane potential", x: 40, y: 400, w: 500, h: 360, color: "#378ADD", at: 1))
        layout.place("source:s0", x: 2000, y: 0, at: 1)
        layout.place("idea:i1", x: 40, y: 40, at: 1)
        layout.place("source:s1", x: 400, y: 40, at: 1)
        layout.place("doc:d1", x: 40, y: 240, at: 1)
        layout.place("clip:h1", x: 60, y: 420, at: 1)
        layout.place("page:s1:7", x: 300, y: 420, at: 1)
        layout.setEdge("e1", .init(from: "idea:i1", to: "source:s1", label: "cites", at: 1))
        let nodes = [
            node("source:s0", "Paper Z", sub: "Smith · 2020 · Cell"),
            node("idea:i1", "Why does ΔΨ drop?", sub: "Maybe the pump\nor the leak"),
            node("source:s1", "PINK1 paper", sub: "Narendra · 2010 · JCB"),
            node("doc:d1", "My notes", sub: "Page"),
            node("clip:h1", "Figure 2", sub: "PINK1 paper · p. 4", h: 200, src: "source:s1"),
            node("page:s1:7", "Page 7", sub: "PINK1 paper", h: 300, src: "source:s1"),
        ]
        return (layout, Dictionary(nodes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    @Test("The whole canvas: loose cards first, regions outermost first with nested ones deeper, then the arrows")
    func wholeCanvas() {
        let (layout, nodes) = sample()
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes)
        let expected = [
            "- [Paper Z](foreverlm://source/s0) — Smith · 2020 · Cell",
            "",
            "## Mitochondria",
            "",
            "- **Why does ΔΨ drop?**",
            "  Maybe the pump  ",
            "  or the leak",
            "- [PINK1 paper](foreverlm://source/s1) — Narendra · 2010 · JCB",
            "- [My notes](foreverlm://doc/d1) — Page",
            "",
            "### Membrane potential",
            "",
            "- [Figure 2](foreverlm://source/s1?page=4) (PINK1 paper, p. 4)",
            "- [Page 7](foreverlm://source/s1?page=7) (PINK1 paper)",
            "",
            "## Connections",
            "",
            "- Why does ΔΨ drop? → PINK1 paper: cites",
            "",
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    @Test("Asking for cards writes only those, with the regions around them, and the arrows between them")
    func selection() {
        let (layout, nodes) = sample()
        let figure = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes, refs: ["clip:h1"])
        #expect(figure == "## Mitochondria\n\n### Membrane potential\n\n- [Figure 2](foreverlm://source/s1?page=4) (PINK1 paper, p. 4)\n")

        let pair = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes, refs: ["idea:i1", "source:s1"])
        #expect(pair.contains("## Connections\n\n- Why does ΔΨ drop? → PINK1 paper: cites"))
        #expect(!pair.contains("Membrane potential"), "a region holding none of them is left out")
        #expect(!pair.contains("My notes"))

        let alone = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes, refs: ["idea:i1"])
        #expect(!alone.contains("Connections"), "an arrow needs both its ends written")
    }

    @Test("Nothing placed, or nothing the library still holds, writes nothing")
    func empty() {
        #expect(KnowledgeMapMarkdown.render(layout: KnowledgeMapLayout(), nodes: [:]).isEmpty)
        var layout = KnowledgeMapLayout()
        layout.place("source:gone", x: 0, y: 0, at: 1)
        #expect(KnowledgeMapMarkdown.render(layout: layout, nodes: [:]).isEmpty)
    }

    @Test("A passage is its quoted words and where they are; a picture is an image; a chat and a canvas are their names")
    func otherKinds() {
        var layout = KnowledgeMapLayout()
        layout.place("clip:p1", x: 0, y: 0, at: 1)
        layout.place("picture:\(imageID)", x: 300, y: 0, at: 1)
        layout.place("chat:c1", x: 600, y: 0, at: 1)
        layout.place("canvas:cnv-x", x: 900, y: 0, at: 1)
        let nodes = [
            node("clip:p1", "p. 4 · PINK1 paper", sub: "PINK1 paper · p. 4", detail: ["Check the units"], quote: "PINK1 builds up\non depolarised mitochondria", src: "source:s1"),
            node("picture:\(imageID)", "Spindle", sub: ""),
            node("chat:c1", "Why PINK1?", sub: "What does PINK1 do?"),
            node("canvas:cnv-x", "Side project", sub: "4 cards · 1 region"),
        ]
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.ref, $0) }))
        #expect(text == [
            "- [“PINK1 builds up on depolarised mitochondria”](foreverlm://source/s1?page=4) (PINK1 paper, p. 4)",
            "  Check the units",
            "- ![Spindle](foreverlm://image/generated/\(imageID))",
            "- [Why PINK1?](foreverlm://chat/c1) — What does PINK1 do?",
            "- Side project — 4 cards · 1 region",
            "",
        ].joined(separator: "\n"))
    }

    @Test("A picture whose id is not an image's is written as its name alone")
    func pictureWithoutAddress() {
        var layout = KnowledgeMapLayout()
        layout.place("picture:x", x: 0, y: 0, at: 1)
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: ["picture:x": node("picture:x", "Spindle")])
        #expect(text == "- ![Spindle]\n")
    }

    @Test("Cards read in rows from the top of the plane, left to right, though a card is a little out of line")
    func readingOrder() {
        var layout = KnowledgeMapLayout()
        layout.place("idea:a", x: 600, y: 10, at: 1)
        layout.place("idea:b", x: 0, y: 30, at: 1)
        layout.place("idea:c", x: 300, y: 0, at: 1)
        layout.place("idea:d", x: 0, y: 400, at: 1)
        let nodes = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map { id in
            ("idea:\(id)", node("idea:\(id)", id.uppercased(), sub: "Idea"))
        })
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes)
        #expect(text == "- **B**\n- **C**\n- **A**\n- **D**\n", "an Idea with no note says only Idea, which is not a note")
    }

    @Test("A region reads in the order the plane does, and a region inside two is three headings deep")
    func regionOrder() {
        var layout = KnowledgeMapLayout()
        layout.setRegion("right", .init(name: "Right", x: 800, y: 0, w: 400, h: 300, color: "#378ADD", at: 1))
        layout.setRegion("left", .init(name: "Left", x: 0, y: 20, w: 700, h: 600, color: "#378ADD", at: 1))
        layout.setRegion("child", .init(name: "Child", x: 20, y: 60, w: 400, h: 400, color: "#378ADD", at: 1))
        layout.setRegion("grand", .init(name: "Grandchild", x: 40, y: 100, w: 200, h: 200, color: "#378ADD", at: 1))
        layout.setRegion("below", .init(name: "Below", x: 0, y: 900, w: 400, h: 300, color: "#378ADD", at: 1))
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: [:])
        #expect(text == "## Left\n\n### Child\n\n#### Grandchild\n\n## Right\n\n## Below\n")
    }

    @Test("Names are one line, and what Markdown would take for style is escaped")
    func escaping() {
        var layout = KnowledgeMapLayout()
        layout.place("source:s", x: 0, y: 0, at: 1)
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: [
            "source:s": node("source:s", "mt_DNA [heteroplasmy]\n*in* aging", sub: "Lee <2020>"),
        ])
        #expect(text == "- [mt\\_DNA \\[heteroplasmy\\] \\*in\\* aging](foreverlm://source/s) — Lee \\<2020\\>\n")
    }

    @Test("An address with brackets or spaces cannot end the link early")
    func destinationIsSafe() {
        #expect(KnowledgeMapMarkdown.destination("https://x.org/a b(c)") == "https://x.org/a%20b%28c%29")
    }

    @Test("A source with no address is its name; links come from the caller")
    func linksFromCaller() {
        var layout = KnowledgeMapLayout()
        layout.place("source:s", x: 0, y: 0, at: 1)
        layout.place("idea:i", x: 300, y: 0, at: 1)
        let nodes = [
            "source:s": node("source:s", "A paper", sub: "Lee · 2020"),
            "idea:i": node("idea:i", "A thought", sub: "Idea"),
        ]
        let plain = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes, linkFor: { _ in nil })
        #expect(plain == "- A paper — Lee · 2020\n- **A thought**\n")
        let web = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes, linkFor: { $0.ref == "source:s" ? "https://doi.org/10.1/x" : nil })
        #expect(web == "- [A paper](https://doi.org/10.1/x) — Lee · 2020\n- **A thought**\n")
    }

    @Test("A page body keeps the headings and lists, links only to the web, and escapes what is written")
    func htmlBody() {
        let (layout, nodes) = sample()
        var tricky = nodes
        tricky["idea:i1"] = node("idea:i1", "Is a<b & \"c\"?", sub: "line one\nline two")
        let outline = KnowledgeMapMarkdown.outline(layout: layout, nodes: tricky, linkFor: { node in
            node.ref == "source:s1" ? "https://doi.org/10.1/pink1" : KnowledgeMapMarkdown.appLink(for: node)
        })
        let html = outline.html
        #expect(html.contains("<h2>Mitochondria</h2>"))
        #expect(html.contains("<h3>Membrane potential</h3>"))
        #expect(html.contains("<a href=\"https://doi.org/10.1/pink1\">PINK1 paper</a> <span class=\"detail\">— Narendra · 2010 · JCB</span>"))
        #expect(html.contains("<strong>Is a&lt;b &amp; &quot;c&quot;?</strong><br>\n<span class=\"note\">line one<br>\nline two</span>"))
        #expect(!html.contains("foreverlm://"), "the app's addresses mean nothing in a browser")
        #expect(html.contains("<li>Is a&lt;b &amp; &quot;c&quot;? → PINK1 paper: cites</li>"))
        #expect(html.contains("<span class=\"detail\">(PINK1 paper, p. 4)</span>"))
    }

    @Test("The app's own address for a card: a source, a Doc, a chat and a picture have one; an Idea and a canvas do not")
    func appLinks() {
        #expect(KnowledgeMapMarkdown.appLink(for: node("idea:i", "x")) == nil)
        #expect(KnowledgeMapMarkdown.appLink(for: node("canvas:c", "x")) == nil)
        #expect(KnowledgeMapMarkdown.appLink(for: node("doc:a b", "x")) == "foreverlm://doc/a%20b")
        #expect(KnowledgeMapMarkdown.appLink(for: node("source:s/1", "x")) == "foreverlm://source/s%2F1")
        #expect(KnowledgeMapMarkdown.appLink(for: node("clip:h", "Figure 1", sub: "Paper · p. 12", src: "source:s")) == "foreverlm://source/s?page=12")
        #expect(KnowledgeMapMarkdown.appLink(for: node("clip:h", "Figure 1", sub: "Paper", src: "source:s")) == "foreverlm://source/s")
        #expect(KnowledgeMapMarkdown.appLink(for: node("clip:h", "Figure 1", sub: "Paper · p. 12")) == nil)
    }
}

@Suite("Canvas: Export as Image and a published page")
struct KnowledgeMapExportTests {
    @Test("The page puts the picture at its head and the outline under it, escapes the name, and carries no script")
    func sitePage() {
        var layout = KnowledgeMapLayout()
        layout.setRegion("r", .init(name: "Mito", x: 0, y: 0, w: 600, h: 400, color: "#378ADD", at: 1))
        layout.place("idea:i", x: 40, y: 40, at: 1)
        let node = KnowledgeMapNode(ref: "idea:i", kind: "idea", type: "idea", title: "Why?", sub: "Idea", detail: [], shore: "")
        let outline = KnowledgeMapMarkdown.outline(layout: layout, nodes: ["idea:i": node])
        let html = KnowledgeMapSitePage.html(title: "Mito & <friends>", outline: outline)
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<title>Mito &amp; &lt;friends&gt;</title>"))
        #expect(html.contains("<h1>Mito &amp; &lt;friends&gt;</h1>"))
        #expect(html.contains("<img src=\"canvas.png\""))
        #expect(html.contains("<h2>Mito</h2>\n<ul>\n<li><strong>Why?</strong></li>\n</ul>"))
        #expect(!html.contains("<script"))
        let picture = html.range(of: "<img")?.lowerBound
        let heading = html.range(of: "<h2>")?.lowerBound
        #expect(picture != nil && heading != nil)
        if let picture, let heading { #expect(picture < heading, "the picture comes first") }
    }

    @Test("The picture's file is named for the canvas, without what a file name cannot hold")
    func fileName() {
        #expect(CanvasExport.fileName(for: "PINK1 / Parkin: notes") == "PINK1 - Parkin- notes.png")
        #expect(CanvasExport.fileName(for: "   ") == "Canvas.png")
    }

    @Test("A scale reads as 1× or 1.5×, and the menu offers one and two")
    func scales() {
        #expect(CanvasExport.scales == [1, 2])
        #expect(CanvasExport.scaleLabel(2) == "2×")
        #expect(CanvasExport.scaleLabel(1.5) == "1.5×")
        #expect(CanvasExport.publishScales.first == 2, "the page's picture is 2× when it fits")
        #expect(CanvasExport.publishScales == CanvasExport.publishScales.sorted(by: >), "then smaller")
    }

    @Test("Why a canvas was not drawn is said in words the learner can act on")
    func errors() {
        #expect(CanvasExportError.notOpen(name: "Ideas").errorDescription?.contains("open it") == true)
        #expect(CanvasExportError.notShowing(name: "Ideas").errorDescription?.contains("Canvas pane") == true)
        #expect(CanvasExportError.nothingToDraw(name: "Ideas").errorDescription == "‘Ideas’ has nothing on it to draw yet.")
    }
}
