import Foundation

// MARK: - A published canvas's page
//
// Publish… renders a canvas as a site of one page through the Sites pipeline
// (docs/knowledge-map-design.md, "Versions, export and publishing"): the
// canvas drawn as a picture at the head, under it the outline of its cards as
// the page's body (`KnowledgeMapOutline.html`). Plain HTML and CSS, no script,
// so it reads the same inside the web host's sandbox and offline.

enum KnowledgeMapSitePage {
    /// The picture's file in the site, beside `index.html`.
    static let imagePath = "canvas.png"

    /// The page's HTML: `title` as the tab's name and the heading, the
    /// picture, then the outline.
    static func html(title: String, outline: KnowledgeMapOutline) -> String {
        let name = KnowledgeMapMarkdown.escapedHTML(KnowledgeMapMarkdown.singleLine(title))
        let body = outline.html
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(name)</title>
        <style>
        :root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --link: #0a64d6; }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #161618; --fg: #f2f2f4; --muted: #9a9aa0; --line: #2c2c30; --link: #6ab0ff; }
        }
        body { margin: 0; background: var(--bg); color: var(--fg); font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        main { max-width: 880px; margin: 0 auto; padding: 40px 20px 80px; }
        h1 { font-size: 2rem; line-height: 1.2; margin: 0 0 24px; }
        figure { margin: 0 0 36px; }
        figure img { display: block; width: 100%; height: auto; background: #ffffff; border: 1px solid var(--line); border-radius: 12px; }
        h2 { font-size: 1.35rem; margin: 36px 0 8px; }
        h3 { font-size: 1.15rem; margin: 28px 0 6px; }
        h4, h5, h6 { font-size: 1rem; margin: 22px 0 4px; }
        ul { padding-left: 1.3em; }
        li { margin: 6px 0; }
        a { color: var(--link); }
        .detail, .note { color: var(--muted); }
        </style>
        </head>
        <body>
        <main>
        <h1>\(name)</h1>
        <figure><a href="\(imagePath)"><img src="\(imagePath)" alt="\(name), drawn as a picture"></a></figure>
        \(body)
        </main>
        </body>
        </html>
        """
    }
}
