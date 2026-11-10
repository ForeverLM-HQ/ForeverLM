// MCPDataStoreTests: sites, linked pages, adopt_page, edit_doc and Notebook archive and summary.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

#if os(macOS)

extension MCPDataStoreTests {
    @Test("save_site keeps the files in the library with a text copy, and nothing goes on the web")
    func mcpSaveSite() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }

        // The files are checked before anything is stored.
        for (html, files, message) in [
            (nil as String?, nil as [Any]?, "Pass the site's files"),
            (nil, [["path": "about.html", "content": "<p>"]] as [Any], "needs an index.html"),
            ("<h1>", [["path": "../x.css", "content": "p{}"]] as [Any], "not a file path"),
            ("<h1>", [["path": "index.html", "content": "<p>"]] as [Any], "entry page once"),
            ("<h1>", [["path": "a.css", "content": "p{}", "content_base64": "cHt9"]] as [Any], "exactly one of"),
        ] {
            do {
                _ = try await store.saveSite(site: nil, title: "Mito", html: html, files: files, repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
                Issue.record("save_site accepted \(message)")
            } catch {
                #expect(error.localizedDescription.contains(message), "\(error.localizedDescription)")
            }
        }
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).isEmpty)

        // Saving needs no account: the site is the library's. html
        // becomes index.html, the entry is a ForeverLM site at its library
        // address, and the visible text is its copy.
        let saved = try parseJSON(try await store.saveSite(
            site: nil, title: "  Mito   Landscape ", html: "<!doctype html><html><head><title>Mito</title><style>h1{}</style></head><body><h1>Mito Landscape</h1><p>Forty &amp; one companies.</p><script>x()</script></body></html>",
            files: [["path": "./css/site.css", "content": "h1{color:red}"], ["path": "img/dot.png", "content_base64": "iVBORw0KGgo="]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(saved["status"] as? String == "saved")
        let docID = try #require(saved["site_id"] as? String)
        #expect(saved["url"] as? String == "foreverlm-site://\(docID)/")
        #expect(saved["files"] as? Int == 3)
        #expect(saved["file_paths"] as? [String] == ["index.html", "css/site.css", "img/dot.png"])
        #expect((saved["message"] as? String)?.contains("never puts a site on the web") == true)
        let doc = try #require(saved["doc"] as? [String: Any])
        #expect(doc["id"] as? String == docID)
        #expect(doc["kind"] as? String == "foreverlm_site")
        #expect(doc["linked_url"] as? String == "foreverlm-site://\(docID)/")
        #expect(doc["read_only"] as? Bool == true)
        #expect(doc["title"] as? String == "Mito Landscape")
        let onDisk = try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: docID))
        #expect(onDisk.map(\.path) == ["css/site.css", "img/dot.png", "index.html"])
        #expect(onDisk.first { $0.path == "img/dot.png" }?.data == Data(base64Encoded: "iVBORw0KGgo=")!)
        let copy = try parseJSON(try await store.readArtifact(artifactID: docID))
        let body = try #require(copy["markdown"] as? String)
        #expect(body.contains("Mito Landscape"))
        #expect(body.contains("Forty & one companies."))
        #expect(!body.contains("x()"))
        let artifacts = try await store.notebookFileStorage.loadArtifacts(notebookID: nil)
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.section == .sites)
        #expect(artifacts.first?.linkedKind == .foreverlmSite)

        // An update by id or by its library address changes only the files it
        // passes; the rest are kept from the library.
        for handle in [docID, "foreverlm-site://\(docID)/css/site.css"] {
            let updated = try parseJSON(try await store.saveSite(
                site: handle, title: nil, html: "<h1>Version two</h1>", files: nil,
                repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
            ))
            #expect(updated["status"] as? String == "updated", Comment(rawValue: handle))
            #expect(updated["site_id"] as? String == docID, Comment(rawValue: handle))
            #expect(updated["kept_files"] as? [String] == ["css/site.css", "img/dot.png"], Comment(rawValue: handle))
            #expect((updated["message"] as? String)?.contains("2 stored files were kept unchanged: css/site.css, img/dot.png") == true, Comment(rawValue: handle))
        }
        #expect(try await store.notebookFileStorage.loadArtifacts(notebookID: nil).first?.title == "Mito Landscape", "an update without a title keeps the entry's")
        #expect((try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String)?.contains("Version two") == true)
        do {
            _ = try await store.saveSite(site: "nowhere-at-all", title: nil, html: "<h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
            Issue.record("an unknown site was updated")
        } catch {
            #expect(error.localizedDescription.contains("No site of yours is named nowhere-at-all"))
        }

        // Files from a repository: read through the injected reader, the
        // commit recorded, skipped files named; no index.html is a refusal.
        let reader: MCPDataStore.SiteRepositoryReader = { repository, path, ref in
            #expect(repository == "acme/site")
            #expect(path == "public")
            #expect(ref == "main")
            return MCPDataStore.SiteRepositoryRead(
                files: [SiteFile(path: "index.html", data: Data("<h1>From git</h1>".utf8)), SiteFile(path: "app.js", data: Data("1".utf8))],
                source: SiteRepositorySource(repository: "acme/site", ref: "main", path: "public", commit: "abc123abc123"),
                skipped: ["public/logo.png (binary)"]
            )
        }
        let fromRepo = try parseJSON(try await store.saveSite(
            site: nil, title: "Acme", html: nil, files: nil, repository: "acme/site", repositoryPath: "public", ref: "main",
            homeNotebookID: nil, notebookIDs: [], readRepository: reader
        ))
        #expect(fromRepo["status"] as? String == "saved")
        #expect((fromRepo["source"] as? [String: Any])?["commit"] as? String == "abc123abc123")
        #expect((fromRepo["skipped"] as? [String]) == ["public/logo.png (binary)"])
        #expect((fromRepo["message"] as? String)?.contains("commit abc123abc123") == true)
        do {
            _ = try await store.saveSite(
                site: nil, title: "Acme", html: "<h1>", files: nil, repository: "acme/site", repositoryPath: nil, ref: nil,
                homeNotebookID: nil, notebookIDs: [], readRepository: reader
            )
            Issue.record("files and a repository were both accepted")
        } catch {
            #expect(error.localizedDescription.contains("not both"))
        }
        let noIndex: MCPDataStore.SiteRepositoryReader = { _, _, _ in
            MCPDataStore.SiteRepositoryRead(files: [SiteFile(path: "README.md", data: Data("x".utf8))], source: SiteRepositorySource(repository: "acme/site"), skipped: [])
        }
        do {
            _ = try await store.saveSite(
                site: nil, title: "Acme", html: nil, files: nil, repository: "acme/site", repositoryPath: nil, ref: nil,
                homeNotebookID: nil, notebookIDs: [], readRepository: noIndex
            )
            Issue.record("a repository without index.html was saved")
        } catch {
            #expect(error.localizedDescription.contains("No index.html"))
        }

        // read_site_file reads the library.
        let read = try parseJSON(try await store.readSiteFile(site: docID, path: "/css/site.css"))
        #expect(read["content"] as? String == "h1{color:red}")
        #expect(read["content_type"] as? String == "text/css")

        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.isSuperset(of: ["save_site", "read_site_file", "replace_site_text"]))
        #expect(toolNames.isDisjoint(with: ["publish_site", "unpublish_site"]), "sites are not put on the web")
    }

    /// `list_source_artifacts`, the tool behind the app's Linked in menu.
    @Test("list_source_artifacts lists the Docs and animations linked to a source, and how")
    func mcpListSourceArtifacts() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(dbPath: dbPath, id: "paper-1", title: "The paper", content: "Body of the paper.", url: "https://doi.org/10.1000/paper-1")
        try insertSource(dbPath: dbPath, id: "other-1", title: "Other", content: "Body.", url: "https://example.com/other")
        SourceArtifactCitationCache.shared.removeAll()

        let animation = try await store.notebookFileStorage.createLinkedArtifact(
            url: URL(string: "foreverlm-site://anim/")!, title: "The animation",
            homeNotebookID: nil, linkedNotebookIDs: [], kind: .animation, sourceIDs: ["paper-1"]
        )
        let citing = try await store.notebookFileStorage.createArtifact(
            title: "Citing Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            markdown: "- [The paper](https://doi.org/10.1000/paper-1) — cited"
        ).artifact
        _ = try await store.notebookFileStorage.createArtifact(
            title: "Unrelated", homeNotebookID: nil, linkedNotebookIDs: [], markdown: "Nothing linked."
        )

        let payload = try parseJSON(try await store.listSourceArtifacts(sourceID: "paper-1"))
        #expect(payload["source_id"] as? String == "paper-1")
        #expect(payload["source_title"] as? String == "The paper")
        #expect(payload["artifact_count"] as? Int == 2)
        let entries = try #require(payload["artifacts"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0["artifact_id"] as? String ?? "", $0) })
        #expect(Set(byID.keys) == [animation.id, citing.id])
        #expect(byID[animation.id]?["linked_by"] as? [String] == ["grounded"])
        #expect(byID[animation.id]?["kind"] as? String == "animation")
        #expect(byID[animation.id]?["url"] as? String == "foreverlm-site://anim/")
        #expect(byID[citing.id]?["linked_by"] as? [String] == ["cited"])
        #expect(byID[citing.id]?["kind"] as? String == "markdown")

        // By the paper's own address, and an empty answer for a source nothing links to.
        let byAddress = try parseJSON(try await store.listSourceArtifacts(sourceID: "https://doi.org/10.1000/paper-1"))
        #expect(byAddress["artifact_count"] as? Int == 2)
        let none = try parseJSON(try await store.listSourceArtifacts(sourceID: "other-1"))
        #expect(none["artifact_count"] as? Int == 0)
        #expect((none["guidance"] as? String)?.contains("Nothing links") == true)
        do {
            _ = try await store.listSourceArtifacts(sourceID: "no-such-source")
            Issue.record("an unknown source went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_sources"))
        }
    }

    /// `replace_site_text`, the tool behind the app's Change action on a
    /// selection in an open Site: the passage is found in the page's source in
    /// the library, changed in place, and saved with every other file kept; a
    /// passage the page has twice, or not at all, is refused.
    @Test("replace_site_text changes one passage of a page in the library and keeps every other file")
    func mcpReplaceSiteText() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let saved = try parseJSON(try await store.saveSite(
            site: nil, title: "Atlas",
            html: "<!doctype html><html><body><p class=\"kicker\">COMPOUNDS WITHOUT A DEVELOPER</p><h2>Real pharmacology, no one carrying it</h2><p>the atlas</p><p>the atlas</p></body></html>",
            files: [["path": "about.html", "content": "<h1>About &amp; more</h1>"], ["path": "css/site.css", "content": "h1{}"]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require(saved["site_id"] as? String)
        func page(_ path: String) async throws -> String {
            let data = try #require(try await store.notebookFileStorage.readLocalSiteFile(artifactID: siteID, path: path))
            return try #require(String(data: data, encoding: .utf8))
        }

        // The screenshot case: a kicker and the heading under it, two elements.
        // No account is needed: the site is the library's.
        let changed = try parseJSON(try await store.replaceSiteText(
            site: siteID, find: "COMPOUNDS WITHOUT A DEVELOPER\nReal pharmacology, no one carrying it",
            replace: "COMPOUNDS WITHOUT AN OWNER\nReal pharmacology, nobody carrying it", path: nil
        ))
        #expect(changed["status"] as? String == "changed")
        #expect(changed["path"] as? String == "index.html")
        #expect(changed["url"] as? String == "foreverlm-site://\(siteID)/")
        #expect((changed["diff"] as? String)?.hasPrefix("- COMPOUNDS WITHOUT A DEVELOPER / Real pharmacology, no one carrying it") == true)
        #expect(try await store.notebookFileStorage.localSiteFilePaths(artifactID: siteID)?.filter { !SiteSourceCards.isGenerated($0) } == ["about.html", "css/site.css", "index.html"], "every other file is kept")
        let html = try await page("index.html")
        #expect(html.contains("<p class=\"kicker\">COMPOUNDS WITHOUT AN OWNER</p><h2>Real pharmacology, nobody carrying it</h2>"))
        #expect(html.contains("<p>the atlas</p><p>the atlas</p>"), "nothing else moved")

        // Another page by its library address, with an entity in the source.
        let about = try parseJSON(try await store.replaceSiteText(
            site: siteID, find: "About & more", replace: "About & less", path: "foreverlm-site://\(siteID)/about.html"
        ))
        #expect(about["path"] as? String == "about.html")
        #expect(about["url"] as? String == "foreverlm-site://\(siteID)/about.html")
        #expect(try await page("about.html") == "<h1>About &amp; less</h1>")

        // Twice on the page: refused with the count; absent: refused; a missing file: refused.
        do {
            _ = try await store.replaceSiteText(site: siteID, find: "the atlas", replace: "an atlas", path: nil)
            Issue.record("an ambiguous passage went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("appears 2 times"))
        }
        do {
            _ = try await store.replaceSiteText(site: siteID, find: "Not on the page", replace: "x", path: nil)
            Issue.record("an absent passage went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("not found in the page's source"))
        }
        do {
            _ = try await store.replaceSiteText(site: siteID, find: "the atlas", replace: "x", path: "missing.html")
            Issue.record("a missing file went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("has no file missing.html"))
        }

    }

    @Test("An update carries only the files that change: stored files are kept, remove_files drops, replace_all replaces, and read_site_file without a path lists the files")
    func mcpSaveSitePartialUpdate() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let first = try parseJSON(try await store.saveSite(
            site: nil, title: "Mitochondrial Therapeutics Atlas", html: "<h1>Atlas</h1>",
            files: [["path": "interventions.html", "content": "<table></table>"], ["path": "css/site.css", "content": "h1{}"]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require(first["site_id"] as? String)
        func paths() async throws -> [String] {
            (try await store.notebookFileStorage.localSiteFilePaths(artifactID: siteID) ?? []).filter { !SiteSourceCards.isGenerated($0) }
        }

        // One page changes; the others are kept from the library.
        let updated = try parseJSON(try await store.saveSite(
            site: siteID, title: nil, html: nil,
            files: [["path": "interventions.html", "content": "<table><tr><td>Elamipretide</td></tr></table>"]],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(try await paths() == ["css/site.css", "index.html", "interventions.html"])
        #expect(updated["kept_files"] as? [String] == ["css/site.css", "index.html"])
        #expect(updated["title"] as? String == "Mitochondrial Therapeutics Atlas")
        let message = try #require(updated["message"] as? String)
        #expect(message.contains("2 stored files were kept unchanged: css/site.css, index.html"))
        #expect(message.contains("only the files that change"))

        // remove_files drops a stored file; a file both passed and removed is
        // refused, and so is removing the entry page without passing one.
        let removed = try parseJSON(try await store.saveSite(
            site: siteID, title: nil, html: nil, files: [["path": "about.html", "content": "<p>About</p>"]],
            repository: nil, repositoryPath: nil, ref: nil, removeFiles: ["/css/site.css"], homeNotebookID: nil, notebookIDs: []
        ))
        #expect(try await paths() == ["about.html", "index.html", "interventions.html"])
        #expect(removed["removed_files"] as? [String] == ["css/site.css"])
        #expect((removed["message"] as? String)?.contains("Removed: css/site.css.") == true)
        do {
            _ = try await store.saveSite(site: siteID, title: nil, html: "<h1>New</h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil, removeFiles: ["index.html"], homeNotebookID: nil, notebookIDs: [])
            Issue.record("a file both passed and removed was accepted")
        } catch {
            #expect(error.localizedDescription.contains("do one or the other"))
        }
        do {
            _ = try await store.saveSite(site: siteID, title: nil, html: nil, files: [["path": "x.css", "content": "p{}"]], repository: nil, repositoryPath: nil, ref: nil, removeFiles: ["index.html"], homeNotebookID: nil, notebookIDs: [])
            Issue.record("a site without index.html was saved")
        } catch {
            #expect(error.localizedDescription.contains("would have no index.html"))
        }

        // replace_all: the passed files are the whole site.
        let replaced = try parseJSON(try await store.saveSite(
            site: siteID, title: nil, html: "<h1>Fresh</h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil,
            replaceAll: true, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(try await paths() == ["index.html"])
        #expect(replaced["kept_files"] == nil)
        do {
            _ = try await store.saveSite(site: siteID, title: nil, html: nil, files: [["path": "a.css", "content": "p{}"]], repository: nil, repositoryPath: nil, ref: nil, replaceAll: true, homeNotebookID: nil, notebookIDs: [])
            Issue.record("replace_all without index.html was accepted")
        } catch {
            #expect(error.localizedDescription.contains("needs an index.html"))
        }

        // A new site needs a title.
        do {
            _ = try await store.saveSite(site: nil, title: nil, html: "<h1>", files: nil, repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
            Issue.record("a new site without a title was accepted")
        } catch {
            #expect(error.localizedDescription.contains("title is required"))
        }

        // read_site_file without a path lists the files — not ForeverLM's own.
        _ = try await store.saveSite(site: siteID, title: nil, html: nil, files: [["path": "pages/two.html", "content": "<p>Two</p>"]], repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: [])
        let listing = try parseJSON(try await store.readSiteFile(site: siteID, path: nil))
        #expect(listing["file_paths"] as? [String] == ["index.html", "pages/two.html"])
        #expect(listing["files"] as? Int == 2)
        #expect(listing["site"] as? String == siteID)
        #expect((listing["message"] as? String)?.contains("only the files that change") == true)
        do {
            _ = try await store.readSiteFile(site: "gone", path: "  ")
            Issue.record("a site the library does not hold was listed")
        } catch {
            #expect(error.localizedDescription.contains("No site or animation of yours is named gone"))
        }
    }

    @Test("save_site draws the library's banner cards: each linked source's thumbnail and one card script join the files, every page loads it once, a source linked by its web address gets the same card, and a copy passed back is remade")
    func mcpSaveSiteSourceCards() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let kstore = try store.knowledgeStore()

        // A paper with its PDF on disk: the first page is the picture the
        // Sources row draws, and the metadata line is author · venue · year.
        let pdfURL = URL(fileURLWithPath: tmpPath).appendingPathComponent("levin.pdf")
        let page = NSImage(size: NSSize(width: 120, height: 160), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        let pdf = PDFDocument()
        pdf.insert(try #require(PDFPage(image: page)), at: 0)
        #expect(pdf.write(to: pdfURL))
        var paper = StudioArticle(
            url: "https://www.mdpi.com/2409-9287/11/1/1", title: "Ingressing Minds", sourceType: .paper,
            localFilePath: pdfURL.path, author: "Michael Levin", journal: "Philosophies", publishedYear: "2026", id: "src-levin-1"
        )
        paper.content = "Patterns in form."
        paper.wordCount = 3
        // Metadata attested, cleanup still queued: the card does not need a
        // finished import, only a source the library holds.
        let attested = paper.attestPaperMetadataExtractionAfterLLM()
        #expect(attested)
        try kstore.saveSource(paper)
        // A post with no file and no artwork: a card with the family glyph that opens its address.
        try Self.seedReadySource(kstore, id: "src-post-1", url: "https://example.com/post", title: "A post", sourceType: .article)


        let html = """
        <!doctype html><html><head><title>Crosswalk</title></head><body>
        <table><tr><td><a href="foreverlm://source/src-levin-1">Ingressing Minds</a></td><td>Primary</td></tr>
        <tr><td><a href="foreverlm://source/src-post-1">A post</a></td><td>Supporting</td></tr>
        <tr><td><a href="foreverlm://source/nope">Missing</a></td><td>Predicted</td></tr></table>
        <p>An inline <a href="foreverlm://source/src-levin-1">citation</a> stays a link.</p>
        <nav><a href="https://example.com/post">Post (menu)</a></nav>
        <p><a href="http://mdpi.com/2409-9287/11/1/1/">Ingressing Minds, by its address</a></p>
        <ul><li><a href='https://example.com/post'>A post, by address</a></li>
        <li><a href="https://example.com/elsewhere">Not in the library</a></li>
        <li><a href="pages/two.html">Own page</a></li></ul>
        </body></html>
        """
        // The cards are drawn at the save.
        let result = try parseJSON(try await store.saveSite(
            site: nil, title: "Crosswalk", html: html,
            files: [
                ["path": "pages/two.html", "content": "<p><a href=\"foreverlm://source/src-levin-1\">Again</a></p>"],
                ["path": "pages/plain.html", "content": "<p>No sources here.</p>"],
                // A stale copy of ForeverLM's own files, as a model passes read_site_file output back.
                ["path": "foreverlm/thumbnails/stale.jpg", "content_base64": "/9j/AAAA"],
                ["path": "foreverlm/source-cards.js", "content": "// old"],
            ],
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        ))
        #expect(result["source_cards"] as? Int == 2)
        #expect(result["unresolved_sources"] as? [String] == ["nope"], "an address the library does not hold is a link, not a missing source")
        // The web addresses the library answered to, as the pages wrote them:
        // the paper under a spelling that only normalizes to its saved address,
        // the post under its own. The site's own page and an unknown address
        // are not sources.
        #expect(result["linked_addresses"] as? [String] == ["https://example.com/post", "http://mdpi.com/2409-9287/11/1/1/"])
        #expect((result["message"] as? String)?.contains("2 of the pages' web links point at a library source") == true)
        #expect((result["message"] as? String)?.contains("2 library sources are drawn as the app's banner card") == true)
        #expect((result["message"] as? String)?.contains("No library source answers to nope") == true)
        let siteID = try #require(result["site_id"] as? String)

        // The library keeps the pages, the picture and the card script.
        let kept = try #require(try await store.notebookFileStorage.localSiteFilePaths(artifactID: siteID))
        #expect(kept == ["foreverlm/source-cards.js", "foreverlm/thumbnails/src-levin-1.jpg", "index.html", "pages/plain.html", "pages/two.html"])
        let savedFiles = try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: siteID))
        let byPath = Dictionary(uniqueKeysWithValues: savedFiles.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == Set(kept))
        let index = try #require(byPath["index.html"].flatMap { String(data: $0.data, encoding: .utf8) })
        let tag = "<script defer src=\"foreverlm/source-cards.js\" data-foreverlm-source-cards></script>"
        #expect(index.components(separatedBy: tag).count == 2, "the entry page loads the card script once")
        #expect(index.contains(tag + "\n</head>"), "before </head>")
        #expect(index.contains("href=\"foreverlm://source/src-levin-1\""), "the links themselves are left for the script")
        let two = try #require(byPath["pages/two.html"].flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(two.contains("<script defer src=\"../foreverlm/source-cards.js\" data-foreverlm-source-cards></script>"), "a page in a folder reaches the script relatively")
        #expect(two.hasPrefix("<p>"), "a page without a head or body gets the tag at its end")
        let plain = try #require(byPath["pages/plain.html"].flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(plain == "<p>No sources here.</p>", "a page that links no source is untouched")
        let jpeg = try #require(byPath["foreverlm/thumbnails/src-levin-1.jpg"]).data
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]), "the thumbnail is a JPEG rendered from the PDF's first page")
        #expect(jpeg.count > 200)
        let script = try #require(byPath["foreverlm/source-cards.js"].flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(script.contains("\"src-levin-1\":{"))
        #expect(script.contains("\"subtitle\":\"Michael Levin · Philosophies · 2026\""))
        #expect(script.contains("\"thumbnail\":\"foreverlm/thumbnails/src-levin-1.jpg\""))
        #expect(script.contains("\"url\":\"https://www.mdpi.com/2409-9287/11/1/1\""))
        #expect(script.contains("\"src-post-1\":{"))
        #expect(script.contains("\"glyph\":\"A\""))
        #expect(script.contains("\"url\":\"https://example.com/post\""))
        #expect(!script.contains("\"nope\""))
        // A card found by address is keyed by the address and opens it — the
        // author's spelling, not the library's public page — with the same
        // picture as the card found by id.
        #expect(script.contains("\"http://mdpi.com/2409-9287/11/1/1/\":{"))
        #expect(script.contains("\"https://example.com/post\":{"))
        #expect(!script.contains("elsewhere"))
        let addressCard = try #require(script.range(of: "\"http://mdpi.com/2409-9287/11/1/1/\":{").map { script[$0.upperBound...] }.map { String($0.prefix(while: { $0 != "}" })) })
        #expect(addressCard.contains("\"url\":\"http://mdpi.com/2409-9287/11/1/1/\""))
        #expect(addressCard.contains("\"thumbnail\":\"foreverlm/thumbnails/src-levin-1.jpg\""))
        #expect(script.contains("scheme === 'http:' || scheme === 'https:'"), "the served script draws a card for a linked address too")
        #expect(script.contains("closest('nav, header, footer')"), "but never inside the page's navigation")
        #expect(script.contains("messageHandlers.linkedPageSourceLinks"), "in the app the script yields to the app's own card")
        #expect(script.contains(SiteSourceCards.cardStyle.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")[0].trimmingCharacters(in: .whitespaces)))
        #expect(!script.contains("__FOREVERLM_"))

        // The saved files passed back as the next save: one tag per page,
        // one picture per source, the script remade — nothing doubles.
        let passedBack: [Any] = savedFiles.map { file -> [String: Any] in
            var entry: [String: Any] = ["path": file.path]
            if let text = String(data: file.data, encoding: .utf8), !SiteFile.looksBinary(file.data) {
                entry["content"] = text
            } else {
                entry["content_base64"] = file.data.base64EncodedString()
            }
            return entry
        }
        _ = try await store.saveSite(
            site: siteID, title: nil, html: nil, files: passedBack,
            repository: nil, repositoryPath: nil, ref: nil, homeNotebookID: nil, notebookIDs: []
        )
        let again = try #require(try await store.notebookFileStorage.localSiteFiles(artifactID: siteID))
        #expect(Set(again.map(\.path)) == Set(byPath.keys))
        let indexAgain = try #require(again.first { $0.path == "index.html" }.flatMap { String(data: $0.data, encoding: .utf8) })
        #expect(indexAgain.components(separatedBy: "data-foreverlm-source-cards").count == 2)
        #expect(indexAgain == index)

        // The pure pieces: link tokens, and the tag's placement.
        #expect(SiteSourceCards.tokens(inHTML: "<a href='foreverlm://source/a%2Db?t=4'>x</a> <a href=\"FOREVERLM://source/c#frag\">y</a> <a href=\"foreverlm://source/a-b\">z</a>") == ["a-b", "c"])
        #expect(SiteSourceCards.tokens(inHTML: "<a href=\"foreverlm://grounding/a\">x</a>") == [])
        // Web addresses: absolute http(s) hrefs as the browser reads them, once
        // each; the site's own pages and source tokens are not addresses.
        #expect(SiteSourceCards.webAddresses(inHTML: "<a href=\"https://a.com/x?y=1&amp;z=2\">x</a> <A HREF = 'HTTP://b.com/'>y</A> <a href=\"pages/two.html\">z</a> <a href=\"foreverlm://source/q\">q</a> <a class=\"k\"\n href=\"https://a.com/x?y=1&amp;z=2\">again</a> <a name=\"anchor\">no href</a>") == ["https://a.com/x?y=1&z=2", "HTTP://b.com/"])
        #expect(SiteSourceCards.injectingScript(into: "<h1>Hi</h1>", path: "a/b/c.html") == "<h1>Hi</h1>\n<script defer src=\"../../foreverlm/source-cards.js\" data-foreverlm-source-cards></script>\n")
        #expect(SiteSourceCards.injectingScript(into: "<html><body><p>x</p>\n</body></html>", path: "index.html") == "<html><body><p>x</p>\n<script defer src=\"foreverlm/source-cards.js\" data-foreverlm-source-cards></script>\n</body></html>")
        #expect(SiteSourceCards.thumbnailPath(forSourceID: "--src/α:1", taken: ["foreverlm/thumbnails/src---1.jpg"]) == "foreverlm/thumbnails/src---1-2.jpg")
        #expect(SiteSourceCards.isGenerated("FOREVERLM/Thumbnails/x.jpg"))
        #expect(!SiteSourceCards.isGenerated("foreverlm/logo.png"))

        func lookup(_ token: String) -> SiteSourceCards.Lookup? {
            let card = SiteSourceCards.Card(sourceID: token, title: token.uppercased(), subtitle: "Paper", kind: "paper", glyph: "P", url: "https://x/\(token)")
            return token == "a" ? .init(card: card, thumbnailJPEG: nil) : nil
        }

        // Addresses are asked together, once each; a match is a card that opens
        // the address the author wrote, and a miss is a link and nothing more.
        var addressed = [SiteFile(path: "index.html", data: Data("<p><a href=\"https://doi.org/10.1/x\">X</a></p><nav><a href=\"https://doi.org/10.1/x\">X</a></nav><p><a href=\"https://nowhere.example/\">N</a></p>".utf8))]
        let addressedAttachment = await SiteSourceCards.attach(to: &addressed, lookup: { _ in nil }, lookupAddresses: { addresses in
            #expect(addresses == ["https://doi.org/10.1/x", "https://nowhere.example/"])
            return ["https://doi.org/10.1/x": lookup("a")!]
        })
        #expect(addressedAttachment.addresses == ["https://doi.org/10.1/x"])
        #expect(addressedAttachment.unresolved.isEmpty)
        #expect(addressedAttachment.cards["https://doi.org/10.1/x"]?.url == "https://doi.org/10.1/x", "the card opens what the author linked, not the library's public page")
        #expect(addressedAttachment.cards["https://doi.org/10.1/x"]?.sourceID == "a")
        #expect(addressed.map(\.path) == ["index.html", SiteSourceCards.scriptPath])
        var unmatched = [SiteFile(path: "index.html", data: Data("<p><a href=\"https://nowhere.example/\">N</a></p>".utf8))]
        let unmatchedAttachment = await SiteSourceCards.attach(to: &unmatched, lookup: { _ in nil }, lookupAddresses: { _ in [:] })
        #expect(unmatchedAttachment == SiteSourceCards.Attachment())
        #expect(unmatched.map(\.path) == ["index.html"], "a site whose links are all ordinary is untouched")
    }

    @Test("adopt_page makes a linked Codex site ForeverLM's own published page, never reaching foreverlm.com in tests")
    func mcpAdoptPage() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let site = try parseJSON(try await store.linkPageArtifact(
            urlString: "mitochondrial-therapeutics-atlas.learner-1234.chatgpt.site",
            title: "Mitochondrial Therapeutics — Company Landscape", homeNotebookID: nil, notebookIDs: []
        ))
        let siteID = try #require((site["doc"] as? [String: Any])?["id"] as? String)
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(
            artifactID: siteID, text: "MITO / LANDSCAPE\n\nCompanies."
        )

        actor Recorder {
            var calls: [(title: String, markdown: String, access: DocPageAccess, slug: String?)] = []
            func record(_ title: String, _ markdown: String, _ access: DocPageAccess, _ slug: String?) {
                calls.append((title, markdown, access, slug))
            }
        }
        let recorder = Recorder()
        let stub: @Sendable (String, String, String, DocPageAccess, String?) async throws -> PublishedDocStatus = { docID, title, markdown, access, slug in
            await recorder.record(title, markdown, access, slug)
            let address = slug ?? "abc123def456"
            return PublishedDocStatus(
                docID: docID, url: URL(string: "https://foreverlm.com/share/\(address)")!, slug: address,
                title: title, publishedAt: Date(), updatedAt: Date(), isProtected: !(access == .keep || access == .open),
                password: nil
            )
        }

        // Signed out: refused before anything changes.
        do {
            _ = try await store.adoptPageArtifact(artifactID: siteID, markdown: nil, readers: nil, slug: nil, isSignedIn: false, publish: stub)
            Issue.record("adopt_page ran signed out")
        } catch {
            #expect(error.localizedDescription.contains("Sign in with Apple"))
            #expect(error.localizedDescription.contains("still a linked Codex Site"))
        }
        let stillLinked = try parseJSON(try await store.readArtifact(artifactID: siteID))
        #expect(stillLinked["kind"] as? String == "codex_site")
        #expect(stillLinked["read_only"] as? Bool == true)
        #expect(await recorder.calls.isEmpty)

        // A Markdown Doc is not a page to adopt.
        let own = try parseJSON(try await store.createArtifact(title: "Own", homeNotebookID: nil, notebookIDs: [], markdown: "# Mine"))
        let ownID = try #require((own["doc"] as? [String: Any])?["id"] as? String)
        do {
            _ = try await store.adoptPageArtifact(artifactID: ownID, markdown: nil, readers: nil, slug: nil, isSignedIn: true, publish: stub)
            Issue.record("adopt_page accepted a Markdown Doc")
        } catch {
            #expect(error.localizedDescription.contains("already a ForeverLM Doc"))
        }
        #expect(await recorder.calls.isEmpty)

        // Signed in, with the site's real Markdown: unlinked, rewritten, published.
        let markdown = "# Mitochondrial therapeutics\n\n## Landscape\n\n- Pharming"
        let adopted = try parseJSON(try await store.adoptPageArtifact(
            artifactID: siteID, markdown: markdown, readers: ["robin@example.com"], slug: "mito-landscape",
            isSignedIn: true, publish: stub
        ))
        #expect(adopted["status"] as? String == "adopted")
        #expect(adopted["url"] as? String == "https://foreverlm.com/share/mito-landscape")
        #expect(adopted["body"] as? String == "markdown")
        #expect(adopted["source_kind"] as? String == "codex_site")
        #expect(adopted["source_url"] as? String == "https://mitochondrial-therapeutics-atlas.learner-1234.chatgpt.site/")
        #expect(adopted["restricted"] as? Bool == true)
        #expect((adopted["message"] as? String)?.contains("edit_doc") == true)
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.title == "Mitochondrial Therapeutics — Company Landscape")
        #expect(calls.first?.markdown == markdown)
        #expect(calls.first?.access == .readers(["robin@example.com"]))
        #expect(calls.first?.slug == "mito-landscape")
        let read = try parseJSON(try await store.readArtifact(artifactID: siteID))
        #expect(read["linked_url"] == nil)
        #expect((read["read_only"] as? Bool) != true)
        #expect(read["markdown"] as? String == markdown)
        #expect(read["revision"] as? String == adopted["revision"] as? String)

        // Without markdown the text copy is the body, and adopting twice is refused: it is a Doc now.
        let second = try parseJSON(try await store.linkPageArtifact(
            urlString: "claude.ai/code/artifact/A1B2C3D4-1E2F-4A5B-8C6D-7E8F9A0B1C2D",
            title: "Atlas", homeNotebookID: nil, notebookIDs: []
        ))
        let secondID = try #require((second["doc"] as? [String: Any])?["id"] as? String)
        _ = try await store.notebookFileStorage.replaceLinkedArtifactExport(artifactID: secondID, text: "# Atlas\n\nCopy.")
        let adoptedCopy = try parseJSON(try await store.adoptPageArtifact(artifactID: secondID, markdown: "  ", readers: nil, slug: nil, isSignedIn: true, publish: stub))
        #expect(adoptedCopy["body"] as? String == "text_copy")
        #expect(adoptedCopy["source_kind"] as? String == "claude_artifact")
        #expect(await recorder.calls.last?.markdown == "# Atlas\n\nCopy.")
        #expect(await recorder.calls.last?.access == .keep)
        await #expect(throws: (any Error).self) {
            _ = try await store.adoptPageArtifact(artifactID: secondID, markdown: nil, readers: nil, slug: nil, isSignedIn: true, publish: stub)
        }
        // The tool is on the server's list.
        let toolNames = Set(MCPToolRegistry.shared.tools.map(\.name))
        #expect(toolNames.contains("adopt_page"))
    }

    @Test("A doc converted to a Google Doc reads as google_doc and read-only through the doc tools")
    func mcpConvertedDocIsReadOnly() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Own words", homeNotebookID: nil, notebookIDs: [], markdown: "# Mine\n\nKept."
        ))
        let createdDoc = try #require(created["doc"] as? [String: Any])
        let docID = try #require(createdDoc["id"] as? String)
        #expect(createdDoc["kind"] as? String == "markdown")

        // What the conversion does once Drive has the copy: the doc becomes
        // a linked doc, the Markdown staying as its body.
        _ = try await store.notebookFileStorage.linkArtifactToGoogleDoc(
            artifactID: docID,
            url: LinkedGoogleDoc.editURL(documentID: "1Conv")
        )

        let listing = try parseJSON(try await store.listArtifacts(notebookID: nil))
        let docs = try #require(listing["docs"] as? [[String: Any]])
        let listed = try #require(docs.first { $0["id"] as? String == docID })
        #expect(listed["kind"] as? String == "google_doc")
        #expect(listed["read_only"] as? Bool == true)
        #expect(listed["linked_url"] as? String == "https://docs.google.com/document/d/1Conv/edit")

        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "# Mine\n\nKept.")
        #expect(read["read_only"] as? Bool == true)
        #expect(read["linked_url"] as? String == "https://docs.google.com/document/d/1Conv/edit")
        #expect((read["guidance"] as? String)?.contains("Google Doc") == true)
        let revision = try #require(read["revision"] as? String)
        // Refused with the route: edit it in Google Docs, refresh the copy with
        // link_page, or unlink it into a Doc of ForeverLM's own.
        do {
            _ = try await store.writeArtifact(
                artifactID: docID,
                markdown: "# Rewritten",
                expectedRevision: revision
            )
            Issue.record("write_doc accepted a linked Google Doc")
        } catch {
            #expect(error.localizedDescription.contains("Google Docs"))
            #expect(error.localizedDescription.contains("unlink_page"))
        }

        // Unlinked, it is an ordinary doc again and the tools may write it.
        _ = try await store.notebookFileStorage.unlinkArtifact(artifactID: docID)
        let restored = try parseJSON(try await store.readArtifact(artifactID: docID))
        let restoredDoc = try #require(restored["doc"] as? [String: Any])
        #expect(restoredDoc["kind"] as? String == "markdown")
        #expect(restoredDoc["read_only"] as? Bool == false)
        #expect(restored["read_only"] == nil)
        let restoredRevision = try #require(restored["revision"] as? String)
        let saved = try parseJSON(try await store.writeArtifact(
            artifactID: docID,
            markdown: "# Mine\n\nRevised.",
            expectedRevision: restoredRevision
        ))
        #expect((saved["revision"] as? String) != restoredRevision)
    }

    @Test("edit_doc changes passages of a Doc in place without carrying its body")
    func mcpEditDocReplacesPassagesInPlace() async throws {
        let (store, tmpPath) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "TechBio report",
            homeNotebookID: nil,
            notebookIDs: [],
            markdown: "# TechBio\n\n## Thesis\n\nOld thesis.\n\n## Companies\n\nAlpha and Beta.\n"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let revision = try #require(created["revision"] as? String)

        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID,
            edits: [
                .init(find: "Old thesis.", replace: "Measurement-led thesis."),
                .init(find: "Alpha and Beta.", replace: "Alpha, Beta and Gamma."),
            ],
            append: "## Open questions\n\n- Which assays predict clinical benefit?\n",
            expectedRevision: revision
        ))
        #expect(edited["replacements"] as? Int == 2)
        #expect(edited["appended"] as? Bool == true)
        let newRevision = try #require(edited["revision"] as? String)
        #expect(newRevision != revision)
        // The result carries no body — that is the point of the tool.
        #expect(edited["markdown"] == nil)

        let read = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(read["markdown"] as? String == "# TechBio\n\n## Thesis\n\nMeasurement-led thesis.\n\n## Companies\n\nAlpha, Beta and Gamma.\n\n## Open questions\n\n- Which assays predict clinical benefit?\n")
        #expect(read["revision"] as? String == newRevision)

        // A stale revision whose find still matches once is no refusal: the
        // edit names its own text (edit_doc applies to the newer body). The
        // rest of this test keeps to the current revision.
        #expect(edited["doc_changed_meanwhile"] == nil)
        // A find that matches nowhere, or in several places, changes nothing
        // and names the edit — a wrong guess at whitespace must not silently
        // rewrite something else.
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [.init(find: "Old thesis.", replace: "x")],
                append: nil,
                expectedRevision: newRevision
            )
            Issue.record("a missing find was applied")
        } catch {
            #expect(error.localizedDescription.contains("edits[0] found no match"))
        }
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [
                    .init(find: "Alpha", replace: "Omega"),
                    .init(find: "##", replace: "#"),
                ],
                append: nil,
                expectedRevision: newRevision
            )
            Issue.record("an ambiguous find was applied")
        } catch {
            #expect(error.localizedDescription.contains("edits[1] matches 3 places"))
        }
        let unchanged = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(unchanged["revision"] as? String == newRevision)
        #expect((unchanged["markdown"] as? String)?.contains("Alpha, Beta and Gamma.") == true)

        // replace_all lifts the single-match rule on purpose.
        let headings = try parseJSON(try await store.editArtifact(
            artifactID: docID,
            edits: [.init(find: "## ", replace: "### ", replaceAll: true)],
            append: nil,
            expectedRevision: newRevision
        ))
        #expect(headings["replacements"] as? Int == 3)
        let reread = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect((reread["markdown"] as? String)?.contains("### Companies") == true)

        // No edits and no append is a caller mistake, not an empty success.
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [],
                append: nil,
                expectedRevision: try #require(headings["revision"] as? String)
            )
            Issue.record("an empty edit was accepted")
        } catch {
            #expect(error.localizedDescription.contains("at least one"))
        }
    }

    @Test("edit_doc lands on a Doc the learner is typing in, and refuses only an edit whose own passage changed")
    func mcpEditDocAppliesToTheNewerBody() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Engineered human resilience",
            homeNotebookID: nil,
            notebookIDs: [],
            markdown: "# Resilience\n\n## Summary\n\nOld summary.\n\n## Mitochondria\n\nOld mitochondria.\n"
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)
        let read = try #require(created["revision"] as? String)

        // 2026-09-29: the learner drafts the next paragraph in the editor,
        // which saves as they type, while the chat rewrites the Summary from
        // the revision it read. The edit goes onto the newer body and the
        // learner's draft stays.
        let typed = try await store.notebookFileStorage.writeArtifactMarkdown(
            artifactID: docID,
            markdown: "# Resilience\n\n## Summary\n\nOld summary.\n\n## Mitochondria\n\nMy own draft of this.\n",
            expectedRevision: read
        )
        let edited = try parseJSON(try await store.editArtifact(
            artifactID: docID,
            edits: [.init(find: "Old summary.", replace: "New summary.")],
            append: nil,
            expectedRevision: read
        ))
        #expect(edited["replacements"] as? Int == 1)
        #expect(edited["doc_changed_meanwhile"] as? Bool == true)
        #expect((edited["doc_changed_guidance"] as? String)?.contains("read_doc") == true)
        let afterEdit = try parseJSON(try await store.readArtifact(artifactID: docID))
        #expect(afterEdit["markdown"] as? String
            == "# Resilience\n\n## Summary\n\nNew summary.\n\n## Mitochondria\n\nMy own draft of this.\n")
        #expect(afterEdit["revision"] as? String == edited["revision"] as? String)
        #expect(edited["revision"] as? String != typed.revision)

        // An edit of the passage the learner rewrote is refused, says why, and
        // changes nothing.
        do {
            _ = try await store.editArtifact(
                artifactID: docID,
                edits: [.init(find: "Old mitochondria.", replace: "Chat's mitochondria.")],
                append: nil,
                expectedRevision: read
            )
            Issue.record("an edit of a passage changed since it was read was applied")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("changed after you read it"))
            #expect(message.contains("edits[0] found no match"))
            #expect(!message.contains("Reload it"))
        }
        #expect(try parseJSON(try await store.readArtifact(artifactID: docID))["revision"] as? String
            == edited["revision"] as? String)

        // write_doc replaces the whole body, so a stale revision still refuses,
        // in words that point at edit_doc, and nothing is saved.
        do {
            _ = try await store.writeArtifact(artifactID: docID, markdown: "# Resilience\n\nGone.", expectedRevision: read)
            Issue.record("write_doc overwrote a newer body")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Nothing was saved"))
            #expect(message.contains("edit_doc"))
        }
        #expect((try parseJSON(try await store.readArtifact(artifactID: docID))["markdown"] as? String)?
            .contains("My own draft of this.") == true)
    }

    @Test("MCP can archive and restore a Notebook without deleting its context")
    func mcpNotebookArchiveIsNonDestructive() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let dbPath = URL(fileURLWithPath: tmpPath).appendingPathComponent("knowledge.db").path
        try insertSource(
            dbPath: dbPath,
            id: "archive-source",
            title: "Context that must survive",
            content: "Preserved source content."
        )
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Archive me",
            topic: "archiving",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: ["archive-source"]
        )

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil,
            status: LearningGoalStatus.archived.rawValue
        )

        let archived = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(archived.isArchived)
        #expect(archived.approvedSourceIDs == ["archive-source"])
        #expect(!((try store.listNotebooks(includeCompleted: false)).contains("Archive me")))
        let archivedListing = try parseJSON(try store.listNotebooks(includeCompleted: true))
        let archivedHeadlines = try #require(archivedListing["goals"] as? [[String: Any]])
        #expect(archivedHeadlines.contains {
            $0["id"] as? String == notebook.id && $0["status"] as? String == "archived"
        })

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil,
            status: LearningGoalStatus.active.rawValue
        )

        let restored = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(restored.lifecycleStatus == .active)
        #expect(restored.approvedSourceIDs == ["archive-source"])
        #expect((try store.listNotebooks(includeCompleted: false)).contains("Archive me"))
    }

    @Test("update_notebook summary sets, reports, and clears the card description")
    func updateNotebookSummary() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "GDF15",
            description: "Cite the assay used.",
            topic: "GDF15",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            summary: "A stress hormone and its receptor",
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil
        )
        let updated = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(updated.summary == "A stress hormone and its receptor")
        // Instructions are a different field and stay put.
        #expect(updated.description == "Cite the assay used.")

        let detail = try parseJSON(try store.getNotebookDetail(notebookID: notebook.id))
        #expect(detail["summary"] as? String == "A stress hormone and its receptor")
        #expect(detail["instructions"] as? String == "Cite the assay used.")

        // Omitted keeps it; "" clears it.
        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: "GDF15 biology",
            description: nil,
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil
        )
        #expect(try #require(try knowledge.loadLearningGoal(notebook.id)).summary == "A stress hormone and its receptor")

        _ = try await store.updateNotebook(
            notebookID: notebook.id,
            title: nil,
            description: nil,
            summary: "",
            topic: nil,
            endDateString: nil,
            openEnded: nil,
            dailyTarget: nil,
            discover: nil
        )
        let cleared = try #require(try knowledge.loadLearningGoal(notebook.id))
        #expect(cleared.summary == nil)
        #expect(try parseJSON(try store.getNotebookDetail(notebookID: notebook.id))["summary"] == nil)
    }

    /// The Goals tab's Delete over MCP (product owner, 2026-09-19: "please give me a
    /// way to delete goals also"): the Goal goes, a Notebook is refused.
    @Test("delete_learning_goal removes a Goal, refuses a Notebook, and names a missing id")
    func deleteLearningGoalOverMCP() async throws {
        let (store, tmpPath) = try makeStore()
        defer { cleanup(tmpPath) }
        let knowledge = try store.knowledgeStore()
        let notebook = try knowledge.createCompanionGoal(
            title: "Pool", description: nil, topic: "pool",
            startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: nil
        )
        let goal = try knowledge.createCompanionGoal(
            title: "Understand the method", description: nil, topic: "method",
            startAt: Date(), endAt: Date().addingTimeInterval(7 * 86_400),
            dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [], parentNotebookID: notebook.id
        )

        let deleted = try parseJSON(try store.deleteLearningGoal(goalID: goal.id))
        #expect(deleted["status"] as? String == "deleted")
        #expect(deleted["goal_id"] as? String == goal.id)
        #expect(try knowledge.loadLearningGoal(goal.id) == nil)
        #expect(try knowledge.loadLearningGoal(notebook.id) != nil, "the Notebook it was tagged to stays")

        do {
            _ = try store.deleteLearningGoal(goalID: notebook.id)
            Issue.record("a Notebook went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("delete_notebook"))
        }
        #expect(try knowledge.loadLearningGoal(notebook.id) != nil)
        do {
            _ = try store.deleteLearningGoal(goalID: goal.id)
            Issue.record("a deleted Goal went through")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("list_goals"))
        }
    }
}

#endif
