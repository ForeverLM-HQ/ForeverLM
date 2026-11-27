import Testing
import Foundation
import AppKit
import WebKit
import UniformTypeIdentifiers
@testable import ForeverLM

@Suite("Artifact Markdown Editor")
struct ArtifactMarkdownEditorViewTests {
    @Test("The Page web view routes only the standard undo and redo shortcuts to its editor history")
    func pageHistoryShortcuts() throws {
        let event = { (characters: String, modifiers: NSEvent.ModifierFlags) in
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 6
            )
        }

        let undo = try #require(event("z", [.command]))
        let redo = try #require(event("z", [.command, .shift]))
        #expect(ArtifactEditorWebView.historyAction(for: undo) == .undo)
        #expect(ArtifactEditorWebView.historyAction(for: redo) == .redo)
        #expect(ArtifactEditorWebView.historyScript(for: .undo) == "window.foreverLMArtifactEditor.performHistoryAction(\"undo\");")
        #expect(ArtifactEditorWebView.historyAction(for: try #require(event("z", [.control]))) == nil)
        #expect(ArtifactEditorWebView.historyAction(for: try #require(event("z", [.command, .option]))) == nil)
        #expect(ArtifactEditorWebView.historyAction(for: try #require(event("x", [.command]))) == nil)
    }

    @Test("A link target reaches the editor as the kind, id, title and detail its picker lists")
    func linkTargetEncodesForTheEditor() throws {
        let targets = [
            ArtifactPageLinkTarget(link: .doc("doc-2"), title: "Mitochondrial landscape", detail: "Draft"),
            ArtifactPageLinkTarget(link: .notebook("p1"), title: "OxPhos", detail: "Notebook"),
        ]
        let data = try JSONEncoder().encode(targets)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(decoded == [
            ["kind": "doc", "id": "doc-2", "title": "Mitochondrial landscape", "detail": "Draft"],
            ["kind": "notebook", "id": "p1", "title": "OxPhos", "detail": "Notebook"],
        ])
        #expect(ArtifactPageLinkTarget(link: .doc("d"), title: "T").detail.isEmpty)
    }

    @Test("A page link's anchor names a block only when it is a block id")
    func pageLinkBlockAnchor() {
        let anchor = { (text: String) in ArtifactMarkdownEditorView.Coordinator.blockAnchor(of: URL(string: text)) }
        #expect(anchor("foreverlm://doc/doc-2#a1b2c3d4e") == "a1b2c3d4e")
        #expect(anchor("https://foreverlm.invalid/doc/doc-2#a1b2c3d4e") == "a1b2c3d4e")
        #expect(anchor("foreverlm://doc/doc-2") == nil)
        #expect(anchor("foreverlm://doc/doc-2#Results") == nil)
        #expect(anchor("foreverlm://doc/doc-2#a1b2c3d4") == nil)
        #expect(StudioEntityLink.parse(destination: "foreverlm://doc/doc-2#a1b2c3d4e") == .doc("doc-2"))
    }

    @Test("A doc's folds are kept by its id, and unfolding it drops the entry")
    func outlineFoldsAreKeptPerDoc() throws {
        let suite = "ArtifactOutlineFoldsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folds = #"{"sections":[],"items":[{"path":["Alpha"],"n":0}]}"#

        #expect(ArtifactOutlineFolds.folds(for: "doc-1", defaults: defaults).isEmpty)
        ArtifactOutlineFolds.set(folds, for: "doc-1", defaults: defaults)
        ArtifactOutlineFolds.set(#"{"sections":[{"title":"B","n":0}],"items":[]}"#, for: "doc-2", defaults: defaults)
        #expect(ArtifactOutlineFolds.folds(for: "doc-1", defaults: defaults) == folds)

        ArtifactOutlineFolds.set("", for: "doc-1", defaults: defaults)
        #expect(ArtifactOutlineFolds.folds(for: "doc-1", defaults: defaults).isEmpty)
        #expect(defaults.dictionary(forKey: ArtifactOutlineFolds.key)?.keys.sorted() == ["doc-2"])
        ArtifactOutlineFolds.set("", for: "doc-2", defaults: defaults)
        #expect(defaults.object(forKey: ArtifactOutlineFolds.key) == nil)
        #expect(!SyncedPreferenceKeys.isSynced(ArtifactOutlineFolds.key))
    }

    @Test("Startup script returns a WebKit-compatible value")
    func startupScriptReturnsSerializableValue() {
        let script = ArtifactMarkdownEditorView.Coordinator.startupScript(
            markdown: "# A \"quoted\" artifact",
            fontSize: 15,
            pageMaxWidth: 760
        )

        #expect(script.contains("create(\"# A \\\"quoted\\\" artifact\", 15.0)"))
        #expect(script.hasSuffix("; true;"))
    }

    @Test("The page width reaches the editor before it is created, and a full page is null")
    func startupScriptSetsPageWidthFirst() {
        let capped = ArtifactMarkdownEditorView.Coordinator.startupScript(
            markdown: "", fontSize: 15, pageMaxWidth: 1040
        )
        #expect(capped.hasPrefix("window.foreverLMArtifactEditor.setPageWidth(1040.0, false);"))
        let setIndex = capped.range(of: "setPageWidth(")!.lowerBound
        let createIndex = capped.range(of: "create(")!.lowerBound
        #expect(setIndex < createIndex)

        #expect(
            ArtifactMarkdownEditorView.Coordinator.pageWidthScript(nil)
                == "window.foreverLMArtifactEditor.setPageWidth(null, false);"
        )
        // The Docs pane keeps the width, so its page's edges drag.
        #expect(
            ArtifactMarkdownEditorView.Coordinator.pageWidthScript(812, adjustable: true)
                == "window.foreverLMArtifactEditor.setPageWidth(812.0, true);"
        )
    }

    @Test("The host tells the slash menu which rows it can answer, once the page is ready")
    func slashFeaturesReachTheEditor() {
        #expect(
            ArtifactMarkdownEditorView.Coordinator.slashFeaturesScript
                == "window.foreverLMArtifactEditor.setSlashFeatures({ pages: true, images: true, imageGeneration: true, visualize: true, files: true });"
        )
    }

    @Test("The top line's tools run rows of the editor's slash list, and a press is its own request")
    func pageToolsRunSlashRows() {
        #expect(ArtifactEditorTool.image.script == "window.foreverLMArtifactEditor.runSlashRow(\"image\");")
        #expect(ArtifactEditorTool.visualize.script == "window.foreverLMArtifactEditor.runSlashRow(\"visualize\");")
        #expect(ArtifactEditorTool.insert.script == "window.foreverLMArtifactEditor.openInsertMenu();")
        // Return in a new page's title puts the caret in the page.
        #expect(ArtifactEditorTool.focus.script == "window.foreverLMArtifactEditor.focus();")
        let first = ArtifactFormatRequest(tool: .image)
        let second = ArtifactFormatRequest(tool: .image)
        #expect(first != second)
        #expect(first.action == .tool(.image))
        #expect(ArtifactFormatRequest(command: .bold).action == .format(.bold))
    }

    @Test("Generate image's request needs an id to answer to and a description to draw")
    func imageGenerationRequestParses() {
        let parsed = ArtifactImageGenerationRequest.parse(["type": "imageGenerationRequested", "requestID": "ai-edit-9", "prompt": "  A mitochondrion in cross section  "])
        #expect(parsed == ArtifactImageGenerationRequest(requestID: "ai-edit-9", prompt: "A mitochondrion in cross section"))
        #expect(ArtifactImageGenerationRequest.parse(["requestID": "ai-edit-9", "prompt": "   "]) == nil)
        #expect(ArtifactImageGenerationRequest.parse(["requestID": "", "prompt": "A cell"]) == nil)
        #expect(ArtifactImageGenerationRequest.parse(["prompt": "A cell"]) == nil)
    }

    @Test("A pasted picture's data URL becomes a file of its own type; anything else is skipped")
    func pastedImagesBecomeFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let payload: [String: Any] = ["type": "imagesPasted", "images": [
            ["name": "Screen Shot 2026/10/12.png", "type": "image/png", "dataURL": "data:image/png;base64," + png.base64EncodedString()],
            ["name": "image.png", "type": "image/png", "dataURL": "data:image/png;base64," + png.base64EncodedString()],
            ["name": "photo.jpeg", "type": "image/jpeg", "dataURL": "data:image/jpeg;base64," + png.base64EncodedString()],
            ["name": "notes.txt", "type": "text/plain", "dataURL": "data:text/plain;base64,aGVsbG8="],
            ["name": "broken.png", "type": "image/png", "dataURL": "data:image/png;base64,***"],
            ["name": "plain.png", "type": "image/png", "dataURL": "data:image/png,not-base64"],
        ]]
        let files = ArtifactPastedImages.files(from: payload, in: directory)
        // The file's name is the picture's alt text; each is in a folder of its own.
        #expect(files.map(\.lastPathComponent) == ["Screen Shot 20261012.png", "Pasted image.png", "photo.jpeg"])
        #expect(Set(files.map { $0.deletingLastPathComponent() }).count == 3)
        #expect(try Data(contentsOf: files[0]) == png)
        #expect(ArtifactPastedImages.files(from: ["images": "nope"], in: directory).isEmpty)
        #expect(ArtifactPastedImages.decode("data:image/gif;base64,") == nil)
    }

    @Test("A drawn picture's alt text is its description on one line, cut at a word under the limit")
    func generatedImageAltText() {
        #expect(ArtifactGeneratedImage.altText(forPrompt: "A cell\nwith a nucleus") == "A cell with a nucleus")
        let long = String(repeating: "mitochondrial cristae ", count: 12)
        let alt = ArtifactGeneratedImage.altText(forPrompt: long)
        #expect(alt.hasSuffix("…"))
        #expect(alt.count <= ArtifactGeneratedImage.altTextLimit + 1)
        #expect(alt.contains("cristae"))
        #expect(!alt.contains("\n"))
    }

    @Test("A drawn picture is answered through completeImageGeneration, a failure through failAIEdit, both escaped")
    func imageGenerationAnswers() throws {
        let image = ArtifactGeneratedImage(token: "tok.png", dataURL: "data:image/png;base64,AAAA", altText: "A \"quoted\" cell")
        let done = ArtifactMarkdownEditorView.Coordinator.imageGenerationScript(requestID: "ai-edit-9", image: image)
        #expect(done.hasPrefix("window.foreverLMArtifactEditor.completeImageGeneration(\"ai-edit-9\", {"))
        #expect(done.contains("\"token\":\"tok.png\""))
        #expect(done.contains("\"dataURL\":\"data:image\\/png;base64,AAAA\"") || done.contains("\"dataURL\":\"data:image/png;base64,AAAA\""))
        #expect(done.contains("A \\\"quoted\\\" cell"))
        #expect(done.hasSuffix("});"))

        let failed = ArtifactMarkdownEditorView.Coordinator.aiEditFailureScript(requestID: "ai-edit-9", message: "Sign in with Apple to use ForeverLM AI.")
        #expect(failed == "window.foreverLMArtifactEditor.failAIEdit(\"ai-edit-9\", \"Sign in with Apple to use ForeverLM AI.\");")
    }

    @Test("A file the host kept is handed to the editor as the token, the name the writer sees and the size, escaped")
    func fileInsertionAnswer() {
        let file = ArtifactFileAttachment(token: "0f1e2d3c-4b5a-4968-8777-665544332211.pdf", name: "Q3 \"final\".pdf", size: 4_096)
        #expect(
            ArtifactMarkdownEditorView.Coordinator.fileInsertionScript(file)
                == "window.foreverLMArtifactEditor.insertFileAttachment({ token: \"0f1e2d3c-4b5a-4968-8777-665544332211.pdf\", name: \"Q3 \\\"final\\\".pdf\", size: 4096 });"
        )
    }

    @Test("Save file… names a token; one with no token is not a request")
    func attachmentOpenRequestParses() {
        let parsed = ArtifactAttachmentOpenRequest.parse(["type": "openAttachmentRequested", "token": " 0f1e2d3c-4b5a-4968-8777-665544332211.pdf ", "name": "Report.pdf"])
        #expect(parsed == ArtifactAttachmentOpenRequest(token: "0f1e2d3c-4b5a-4968-8777-665544332211.pdf", name: "Report.pdf"))
        #expect(ArtifactAttachmentOpenRequest.parse(["token": "t"]) == ArtifactAttachmentOpenRequest(token: "t", name: ""))
        #expect(ArtifactAttachmentOpenRequest.parse(["name": "Report.pdf"]) == nil)
        #expect(ArtifactAttachmentOpenRequest.parse(["token": "   "]) == nil)
    }

    @Test("A picture the page registered itself needs no whole-map redraw; one it has never seen does")
    func attachmentsAreSentOnlyWhenThePageLacksOne() {
        let host = ["a.png": "data:a", "b.png": "data:b"]
        #expect(!ArtifactMarkdownEditorView.Coordinator.pageNeedsAttachments(host: host, pageTokens: ["a.png", "b.png"]))
        #expect(!ArtifactMarkdownEditorView.Coordinator.pageNeedsAttachments(host: ["a.png": "data:a"], pageTokens: ["a.png", "b.png"]), "a picture the host dropped changes nothing the page shows")
        #expect(ArtifactMarkdownEditorView.Coordinator.pageNeedsAttachments(host: host, pageTokens: ["a.png"]))
        #expect(!ArtifactMarkdownEditorView.Coordinator.pageNeedsAttachments(host: [:], pageTokens: []))
    }

    @Test("Page widths: standard is the stylesheet's 760, 0 fills the pane, and a dragged width is kept to the point")
    func pageWidthChoices() {
        #expect(ArtifactPageWidth.maxWidth(ArtifactPageWidth.standard) == 760)
        #expect(ArtifactPageWidth.maxWidth(ArtifactPageWidth.full) == nil)
        #expect(ArtifactPageWidth.presets.map(\.title) == ["Standard", "Wide", "Full Width"])
        #expect(ArtifactPageWidth.presets[1].width > 760)
        // A dragged width goes back and forth unchanged, so the editor is not
        // sent the width it just drew.
        #expect(ArtifactPageWidth.stored(912) == 912)
        #expect(ArtifactPageWidth.maxWidth(ArtifactPageWidth.stored(912)) == 912)
        #expect(ArtifactPageWidth.stored(nil) == ArtifactPageWidth.full)
        // Nothing narrower than the editor's own floor.
        #expect(ArtifactPageWidth.maxWidth(120) == 400)
        #expect(ArtifactPageWidth.stored(120) == 400)
        #expect(ArtifactPageWidth.maxWidth(-5) == nil)
        #expect(ArtifactPageWidth.maxWidth(.nan) == nil)
    }

    @Test("The title's inset follows the page width the reader chose")
    func pageInsetFollowsPageWidth() {
        // A standard page in a 2000pt pane is centred: (2000 - 760) / 2 plus the
        // 48pt side padding the stylesheet clamps to.
        #expect(ArtifactPageGeometry.inset(paneWidth: 2000, pageMaxWidth: 760) == 668)
        // Wider page, less blank pane either side.
        #expect(ArtifactPageGeometry.inset(paneWidth: 2000, pageMaxWidth: 1040) == 528)
        // A full page has only its side padding.
        #expect(ArtifactPageGeometry.inset(paneWidth: 2000, pageMaxWidth: nil) == 48)
        // A pane narrower than the cap: every width is the same page.
        for cap in [CGFloat(760), 1040] {
            #expect(ArtifactPageGeometry.inset(paneWidth: 600, pageMaxWidth: cap) == 36)
        }
        #expect(ArtifactPageGeometry.inset(paneWidth: 600, pageMaxWidth: nil) == 36)
        // Nothing measured yet: the resting inset.
        #expect(ArtifactPageGeometry.inset(paneWidth: 0, pageMaxWidth: 760) == 28)
    }

    @Test("First top-level heading becomes the placeholder note title")
    func firstMarkdownTitle() {
        #expect(ArtifactMarkdownTitle.first(in: "\n# Mitochondrial therapeutics in 2026\n\nNotes") == "Mitochondrial therapeutics in 2026")
        #expect(ArtifactMarkdownTitle.first(in: "Intro\n\n# Later heading") == nil)
        #expect(ArtifactMarkdownTitle.first(in: "## Section") == nil)
        // Blank and whitespace-only lines are skipped; the heading is trimmed.
        #expect(ArtifactMarkdownTitle.first(in: "  \n\t\n# Indented  ") == "Indented")
        #expect(ArtifactMarkdownTitle.first(in: "# Only heading") == "Only heading")
        #expect(ArtifactMarkdownTitle.first(in: "# ") == nil)
        #expect(ArtifactMarkdownTitle.first(in: "") == nil)
    }

    @Test("A doc whose first heading is its title is named by the heading")
    func headingNamesDoc() {
        let body = "# The Landscape of Mitochondrial Therapeutics\n\nThis is the canonical overview."
        #expect(ArtifactMarkdownTitle.names("The Landscape of Mitochondrial Therapeutics", in: body))
        #expect(ArtifactMarkdownTitle.names(" The Landscape of Mitochondrial Therapeutics \n", in: body))
        // Case is not a difference, as on the published page.
        #expect(ArtifactMarkdownTitle.names("the landscape of mitochondrial therapeutics", in: body))
        // A different name is not the heading; the page takes the heading's words (`adoptedTitle`).
        #expect(!ArtifactMarkdownTitle.names("Research notes: mitochondria", in: body))
        #expect(!ArtifactMarkdownTitle.names("The Landscape of Mitochondrial Therapeutics", in: "Intro\n\n# The Landscape of Mitochondrial Therapeutics"))
        #expect(!ArtifactMarkdownTitle.names("Untitled Doc", in: ""))
    }

    @Test("A page stored under a different wording than its heading takes the heading's words")
    func headingIsTheOnlyName() {
        // The reported page: the title said "Field session 2026-10-25 - my notes",
        // the body's heading "Field session 2026-10-25: my notes", and the page drew both.
        let body = "# Field session 2026-10-25: my notes\n\nWhat we covered."
        let stored = "Field session 2026-10-25 \u{2014} my notes"
        #expect(!ArtifactMarkdownTitle.names(stored, in: body))
        #expect(ArtifactMarkdownTitle.adoptedTitle(replacing: stored, in: body) == "Field session 2026-10-25: my notes")
        // A title that is the heading, or differs only in the spaces around it, has nothing to adopt.
        #expect(ArtifactMarkdownTitle.adoptedTitle(replacing: " Field session 2026-10-25: my notes ", in: body) == nil)
        // Case is a difference: two strings are one only when they match.
        #expect(ArtifactMarkdownTitle.adoptedTitle(replacing: "field session 2026-10-25: my notes", in: body) == "Field session 2026-10-25: my notes")
        // A body with no opening heading names nothing; the title stands.
        #expect(ArtifactMarkdownTitle.adoptedTitle(replacing: stored, in: "Intro\n\n# Later heading") == nil)
        #expect(ArtifactMarkdownTitle.adoptedTitle(replacing: stored, in: "") == nil)
    }

    @Test("A rename writes the new words into the opening heading and nothing else")
    func retitlingTheOpeningHeading() {
        let body = "\n  # Old name  \n\nFirst paragraph.\n\n# A later heading\n"
        #expect(ArtifactMarkdownTitle.retitling(body, to: "New name") == "\n# New name\n\nFirst paragraph.\n\n# A later heading\n")
        // Several lines of title are one line of heading.
        #expect(ArtifactMarkdownTitle.retitling("# Old", to: "New\n  name") == "# New name")
        // Nothing to write: the heading already says it, there is none, or the title is empty.
        #expect(ArtifactMarkdownTitle.retitling("# Same\n\nText", to: "Same") == nil)
        // Spacing alone is no rename: the editor renames to the heading it just saved,
        // and rewriting a half-typed heading's trailing space raced the next save.
        #expect(ArtifactMarkdownTitle.retitling("# Takeaways from teh \n\nText", to: "Takeaways from teh") == nil)
        #expect(ArtifactMarkdownTitle.retitling("#  Two  spaces\n", to: "Two spaces") == nil)
        // A change of case is still a rename.
        #expect(ArtifactMarkdownTitle.retitling("# same", to: "Same") == "# Same")
        #expect(ArtifactMarkdownTitle.retitling("Text\n\n# Later", to: "New") == nil)
        #expect(ArtifactMarkdownTitle.retitling("## Section", to: "New") == nil)
        #expect(ArtifactMarkdownTitle.retitling("# Old", to: "  \n") == nil)
        // What a rename writes is read back as the title, so the two cannot differ afterwards.
        let renamed = ArtifactMarkdownTitle.retitling("# Old\n\nText", to: "New name")
        #expect(renamed.flatMap { ArtifactMarkdownTitle.first(in: $0) } == "New name")
    }

    @Test("Only an ordinary Markdown page is named by its body")
    func onlyOrdinaryPagesTakeTheirHeading() {
        let now = Date()
        func record(id: String = "page-1", kind: ArtifactKind? = nil, linkedURL: String? = nil) -> ArtifactRecord {
            ArtifactRecord(id: id, title: "Notes", homeNotebookID: nil, linkedNotebookIDs: [], linkedURL: linkedURL, kind: kind, createdAt: now, updatedAt: now)
        }
        #expect(ArtifactMarkdownTitle.canBeNamedByBody(record()))
        #expect(!ArtifactMarkdownTitle.canBeNamedByBody(record(kind: .animation)))
        #expect(!ArtifactMarkdownTitle.canBeNamedByBody(record(linkedURL: "https://docs.google.com/document/d/1AbC/edit")))
        #expect(!ArtifactMarkdownTitle.canBeNamedByBody(record(id: DailyNote.id(forDayKey: "2026-10-25"))))
    }

    @Test("A new page is Untitled Page, and every earlier default still counts as unnamed")
    func placeholderTitles() {
        #expect(ArtifactPlaceholderTitle.current == "Untitled Page")
        #expect(ArtifactPlaceholderTitle.isPlaceholder("Untitled Page"))
        // Stored pages made while the feature was called Docs, or Notes.
        #expect(ArtifactPlaceholderTitle.isPlaceholder("Untitled Doc"))
        #expect(ArtifactPlaceholderTitle.isPlaceholder("Untitled Note"))
        #expect(!ArtifactPlaceholderTitle.isPlaceholder("The Landscape of Mitochondrial Therapeutics"))
    }

    @Test("A highlighted phrase seeds the source picker's search; a paragraph does not")
    func sourcePickerSeedQuery() {
        #expect(ArtifactSourceSeedQuery.from("NAD(P)H fluorescence") == "NAD(P)H fluorescence")
        #expect(ArtifactSourceSeedQuery.from("  mitochondrial\n membrane potential.  ") == "mitochondrial membrane potential")
        #expect(ArtifactSourceSeedQuery.from("“Sirtuins”") == "Sirtuins")
        #expect(ArtifactSourceSeedQuery.from("   ") == "")
        // A whole passage names no source, so the picker opens on the full library.
        #expect(ArtifactSourceSeedQuery.from(
            "Mitochondrial membrane potential and NAD(P)H fluorescence both track with remaining lifespan in individual cells."
        ) == "")
    }

    @Test("Book citations preserve their collection identity for editor insertion")
    func bookCitationEncoding() throws {
        let citation = ArtifactSourceCitation(
            sourceID: "chapter-1",
            title: "How Life Works",
            bookID: "book-how-life-works"
        )
        let json = String(decoding: try JSONEncoder().encode(citation), as: UTF8.self)

        #expect(json.contains("\"sourceID\":\"chapter-1\""))
        #expect(json.contains("\"bookID\":\"book-how-life-works\""))

        let bareJSON = Data(#"{"sourceID":"chapter-1","title":"Genes"}"#.utf8)
        let bareCitation = try JSONDecoder().decode(ArtifactSourceCitation.self, from: bareJSON)
        #expect(bareCitation.bookID == nil)
    }
}

/// The page's text held out of the editor host's observed state: a report
/// replaces it and starts the autosave's pause over (docs/codex-parity-audit.md, F3).
@Suite("Page draft held outside the view")
@MainActor
struct ArtifactEditorDraftTests {
    @Test("Reports in quick succession save once, after the text stands still, with the last text")
    func autosaveRunsOnceAfterThePause() async throws {
        let draft = ArtifactEditorDraft()
        var saved: [String] = []
        for words in ["The", "The cell", "The cell divides."] {
            #expect(draft.replaceText(with: words, autosaveAfter: .milliseconds(80), save: { saved.append(draft.text) }))
        }
        #expect(saved.isEmpty, "nothing is written while the writer is still typing")
        try await Task.sleep(for: .milliseconds(600))
        #expect(saved == ["The cell divides."])
    }

    @Test("The same text is no change: no autosave starts, and the caller is told")
    func sameTextIsNoChange() async throws {
        let draft = ArtifactEditorDraft()
        var saves = 0
        #expect(draft.replaceText(with: "Mitosis", autosaveAfter: .milliseconds(40), save: { saves += 1 }))
        try await Task.sleep(for: .milliseconds(400))
        #expect(saves == 1)
        #expect(!draft.replaceText(with: "Mitosis", autosaveAfter: .milliseconds(40), save: { saves += 1 }))
        try await Task.sleep(for: .milliseconds(400))
        #expect(saves == 1)
    }

    @Test("A page closing ends the pause without a save")
    func closingCancelsTheAutosave() async throws {
        let draft = ArtifactEditorDraft()
        var saves = 0
        draft.replaceText(with: "Last words before ⌘W", autosaveAfter: .milliseconds(80), save: { saves += 1 })
        draft.cancelAutosave()
        try await Task.sleep(for: .milliseconds(500))
        #expect(saves == 0)
        #expect(draft.text == "Last words before ⌘W", "the text stays for the closing save")
    }
}

/// The source drag from the sidebar lands on the editor's web view, because
/// WebKit registers for the file, URL and text types the same drag advertises
/// for other apps, and AppKit hands the whole drag to the deepest registered
/// view. A SwiftUI drop target above the web view never fires, which is how
/// the drop went unnoticed as broken while the browser harness passed.
@Suite("Artifact Editor Page Drag")
@MainActor
struct ArtifactEditorPageDragTests {
    private final class Recorder {
        var targeted: [Bool] = []
        var moved: [(ArtifactPageDragKind, CGPoint?)] = []
        var dropped: [(ArtifactPageDrop, CGPoint)] = []
        var movedPoints: [CGPoint?] { moved.map { $0.1 } }
    }

    /// Only what the web view reads. Nothing here reaches WebKit: every call
    /// under test is answered by the subclass before `super` is consulted.
    private final class DragInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        init(pasteboard: NSPasteboard, location: NSPoint) {
            draggingPasteboard = pasteboard
            draggingLocation = location
        }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var draggingFormation: NSDraggingFormation = .default
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func resetSpringLoading() {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ArtifactEditorPageDragTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// What `articleDragProvider` puts on the pasteboard: the in-app transfer
    /// beside the file promise and PDF data that make WebKit want the drag.
    private func sourcePasteboard(_ transfer: StudioArticleTransfer) throws -> NSPasteboard {
        let pasteboard = pasteboard()
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(transfer), forType: ArtifactEditorWebView.sourceTransferType)
        item.setData(Data([0x25, 0x50, 0x44, 0x46]), forType: .pdf)
        item.setString("file:///tmp/paper.pdf", forType: .fileURL)
        pasteboard.writeObjects([item])
        return pasteboard
    }

    /// What `studioArtifactDragProvider` puts on the pasteboard: the doc alone,
    /// with no string or file representation for WebKit to want.
    private func docPasteboard(_ transfer: StudioArtifactTransfer) throws -> NSPasteboard {
        let pasteboard = pasteboard()
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(transfer), forType: ArtifactEditorWebView.artifactTransferType)
        pasteboard.writeObjects([item])
        return pasteboard
    }

    private func notebookPasteboard(_ transfer: StudioNotebookTransfer) throws -> NSPasteboard {
        let pasteboard = pasteboard()
        let item = NSPasteboardItem()
        item.setData(try JSONEncoder().encode(transfer), forType: ArtifactEditorWebView.notebookTransferType)
        pasteboard.writeObjects([item])
        return pasteboard
    }

    private func makeWebView(_ recorder: Recorder) -> ArtifactEditorWebView {
        let webView = ArtifactEditorWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        webView.pageDrag = ArtifactPageDragHandling(
            targeted: { recorder.targeted.append($0) },
            moved: { recorder.moved.append(($0, $1)) },
            dropped: { recorder.dropped.append(($0, $1)) }
        )
        return webView
    }

    @Test("The web view registers for the doc and Notebook drag types WebKit does not know")
    func registersInAppTypes() {
        let webView = ArtifactEditorWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let registered = Set(webView.registeredDraggedTypes.map(\.rawValue))
        #expect(registered.contains(UTType.studioArtifact.identifier))
        #expect(registered.contains(UTType.studioNotebook.identifier))
        #expect(registered.contains(UTType.studioGroup.identifier))
        // The source drag needs no registration of ours: WebKit claims every
        // drag over the view, so the subclass only has to recognise the type.
        #expect(!registered.contains(UTType.studioArticle.identifier))
    }

    @Test("A source drag over the page is claimed and followed in page coordinates")
    func sourceDragIsClaimed() throws {
        let recorder = Recorder()
        let webView = makeWebView(recorder)
        let pasteboard = try sourcePasteboard(StudioArticleTransfer(articleId: "s1", articleIds: ["s1"], title: "Urolithin A", sourceType: "paper"))

        // The view is flipped, so a point 10pt below its top edge arrives as y = 10.
        let entered = webView.draggingEntered(DragInfo(pasteboard: pasteboard, location: NSPoint(x: 10, y: 290)))
        #expect(entered == .copy)
        #expect(recorder.targeted == [true])
        #expect(recorder.movedPoints == [CGPoint(x: 10, y: 10)])
        #expect(recorder.moved.map { $0.0 } == [.sources])

        let updated = webView.draggingUpdated(DragInfo(pasteboard: pasteboard, location: NSPoint(x: 40, y: 200)))
        #expect(updated == .copy)
        #expect(recorder.movedPoints.last == CGPoint(x: 40, y: 100))

        webView.draggingExited(nil)
        #expect(recorder.movedPoints.last == .some(nil))
        #expect(recorder.targeted == [true, false])
    }

    @Test("A drop hands every dragged source and the landing point to the host")
    func sourceDropIsDelivered() throws {
        let recorder = Recorder()
        let webView = makeWebView(recorder)
        let transfer = StudioArticleTransfer(articleId: "s1", articleIds: ["s1", "s2", "s3"], title: "3 sources", sourceType: "selection")
        let pasteboard = try sourcePasteboard(transfer)
        let info = DragInfo(pasteboard: pasteboard, location: NSPoint(x: 120, y: 60))

        _ = webView.draggingEntered(info)
        #expect(webView.prepareForDragOperation(info))
        #expect(webView.performDragOperation(info))
        webView.concludeDragOperation(info)
        webView.draggingEnded(info)

        #expect(recorder.dropped.count == 1)
        guard case .sources(let transfers)? = recorder.dropped.first?.0 else {
            Issue.record("Expected a source drop")
            return
        }
        #expect(transfers.map { $0.articleId } == ["s1"])
        #expect(transfers.first?.articleIds == ["s1", "s2", "s3"])
        #expect(recorder.dropped.first?.1 == CGPoint(x: 120, y: 240))
        #expect(recorder.targeted.last == false)
        #expect(recorder.movedPoints.last == .some(nil))
    }

    @Test("A doc dragged from the Docs list is claimed as a link drag and lands with its title")
    func docDragBecomesLink() throws {
        let recorder = Recorder()
        let webView = makeWebView(recorder)
        let pasteboard = try docPasteboard(StudioArtifactTransfer(artifactID: "doc-42", title: "Reading notes"))
        let info = DragInfo(pasteboard: pasteboard, location: NSPoint(x: 80, y: 250))

        #expect(webView.draggingEntered(info) == .copy)
        #expect(recorder.moved.map { $0.0 } == [.links])
        #expect(recorder.movedPoints == [CGPoint(x: 80, y: 50)])
        #expect(webView.performDragOperation(info))
        webView.draggingEnded(info)

        guard case .links(let transfers)? = recorder.dropped.first?.0 else {
            Issue.record("Expected a link drop")
            return
        }
        #expect(transfers == [ArtifactPageLinkTransfer(link: .doc("doc-42"), title: "Reading notes")])
        #expect(recorder.dropped.first?.1 == CGPoint(x: 80, y: 50))
    }

    @Test("A Notebook dragged from the rail lands as a link with no title of its own")
    func notebookDragBecomesLink() throws {
        let recorder = Recorder()
        let webView = makeWebView(recorder)
        let pasteboard = try notebookPasteboard(StudioNotebookTransfer(notebookID: "proj-7"))
        let info = DragInfo(pasteboard: pasteboard, location: NSPoint(x: 30, y: 30))

        #expect(webView.draggingEntered(info) == .copy)
        #expect(webView.performDragOperation(info))
        webView.draggingEnded(info)

        guard case .links(let transfers)? = recorder.dropped.first?.0 else {
            Issue.record("Expected a link drop")
            return
        }
        #expect(transfers == [ArtifactPageLinkTransfer(link: .notebook("proj-7"), title: nil)])
        #expect(recorder.dropped.first?.1 == CGPoint(x: 30, y: 270))
    }

    @Test("A book dragged from the Books list is claimed as a source drag and lands as its chapters")
    func bookDropIsDelivered() throws {
        let recorder = Recorder()
        let webView = makeWebView(recorder)
        // What `groupDragProvider` puts on the pasteboard: the group alone.
        let pasteboard = pasteboard()
        let item = NSPasteboardItem()
        item.setData(
            try JSONEncoder().encode(StudioGroupTransfer(groupName: "book-7", sourceIDs: ["c1", "c2", "c3"])),
            forType: ArtifactEditorWebView.groupTransferType
        )
        pasteboard.writeObjects([item])
        let info = DragInfo(pasteboard: pasteboard, location: NSPoint(x: 30, y: 30))

        #expect(webView.draggingEntered(info) == .copy)
        #expect(recorder.moved.map { $0.0 } == [.sources])
        #expect(webView.performDragOperation(info))
        webView.draggingEnded(info)

        guard case .sources(let transfers)? = recorder.dropped.first?.0 else {
            Issue.record("Expected a source drop")
            return
        }
        #expect(transfers.count == 1)
        #expect(transfers.first?.draggedSourceIDs == ["c1", "c2", "c3"])
        #expect(transfers.first?.title == "book-7")
        #expect(transfers.first?.isGroup == true)
        // An ordinary source drag is not a group, and a group with nothing in it is no drag.
        #expect(!StudioArticleTransfer(articleId: "s1", articleIds: ["s1"], title: "T", sourceType: "paper").isGroup)
        #expect(StudioArticleTransfer(group: StudioGroupTransfer(groupName: "empty", sourceIDs: [])) == nil)
        #expect(StudioArticleTransfer(group: StudioGroupTransfer(groupName: "unnamed")) == nil)
    }

    @Test("The pasteboard's source payload decodes from the in-app type")
    func sourceTransfersDecode() throws {
        let pasteboard = try sourcePasteboard(StudioArticleTransfer(articleId: "s9", articleIds: ["s9"], title: "MitoRx", sourceType: "article"))
        let transfers = ArtifactEditorWebView.sourceTransfers(on: pasteboard)
        #expect(transfers.map { $0.articleId } == ["s9"])
        #expect(transfers.first?.title == "MitoRx")

        let empty = NSPasteboard(name: NSPasteboard.Name("ArtifactEditorPageDragTests-empty-\(UUID().uuidString)"))
        empty.clearContents()
        empty.setString("just text", forType: .string)
        #expect(ArtifactEditorWebView.sourceTransfers(on: empty).isEmpty)
        #expect(ArtifactEditorWebView.linkTransfers(on: empty).isEmpty)
    }
}

/// A chat's source card drags as WebKit drags any link: the address and its
/// words on the pasteboard. These pin how that drag becomes the sidebar's
/// source drag, so the Doc page — and every other source destination — takes it.
@Suite("Source link drag")
struct SourceLinkDragTests {
    private func linkPasteboard(_ address: String, title: String? = nil) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SourceLinkDragTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(address, forType: .URL)
        item.setString(address, forType: .string)
        if let title { item.setString(title, forType: SourceLinkDrag.urlNameType) }
        pasteboard.writeObjects([item])
        return pasteboard
    }

    @Test("A dragged source link gains the in-app source payload, named by the card the row showed")
    func claimsSourceLink() throws {
        let pasteboard = linkPasteboard("foreverlm://source/src_abc12345", title: "[1]Hypermetabolism…Paper · 2023")
        let written = SourceLinkDrag.claim(pasteboard) { token in
            #expect(token == "src_abc12345")
            return StudioArticleTransfer(articleId: "src_abc12345_full", articleIds: ["src_abc12345_full"], title: "Hypermetabolism", sourceType: "paper")
        }
        #expect(written?.articleId == "src_abc12345_full")
        let transfers = ArtifactEditorWebView.sourceTransfers(on: pasteboard)
        #expect(transfers.map(\.articleId) == ["src_abc12345_full"])
        #expect(transfers.first?.title == "Hypermetabolism")
        #expect(transfers.first?.sourceType == "paper")
        // WebKit's own items are still there for a browser to take.
        #expect(pasteboard.string(forType: .URL) == "foreverlm://source/src_abc12345")
        // A second claim of the same drag writes nothing more.
        #expect(SourceLinkDrag.claim(pasteboard) { _ in nil } == nil)
    }

    @Test("A source the row has no card for is named by its id and the link's words")
    func fallsBackToTheLink() throws {
        let pasteboard = linkPasteboard("foreverlm://source/src_unknown99?t=12", title: "Some title")
        let written = SourceLinkDrag.claim(pasteboard) { _ in nil }
        #expect(written?.articleId == "src_unknown99")
        #expect(written?.title == "Some title")
        #expect(ArtifactEditorWebView.sourceTransfers(on: pasteboard).map(\.articleId) == ["src_unknown99"])
    }

    @Test("A web link, or a doc link, is not a source drag")
    func leavesOtherLinksAlone() throws {
        for address in ["https://www.nature.com/articles/s41586-021-03819-2", "foreverlm://doc/abc-1"] {
            let pasteboard = linkPasteboard(address, title: "Title")
            #expect(SourceLinkDrag.claim(pasteboard) { _ in nil } == nil)
            #expect(pasteboard.availableType(from: [SourceLinkDrag.sourceTransferType]) == nil)
            #expect(ArtifactEditorWebView.sourceTransfers(on: pasteboard).isEmpty)
        }
    }

    @Test("WKWebView still owns the start of its drag sessions, so the chat view forwards to it")
    func webKitImplementsWillBegin() {
        #expect(SourceLinkDrag.implementsWillBegin(WKWebView.self))
    }
}

@Suite("Studio Entity Link")
struct StudioEntityLinkTests {
    @Test("A doc or Notebook link parses from the stored, runtime and editor spellings")
    func parsesEverySpelling() throws {
        #expect(StudioEntityLink.parse(destination: "foreverlm://doc/abc-1") == .doc("abc-1"))
        #expect(StudioEntityLink.parse(destination: "foreverlm://notebook/p%20q") == .notebook("p q"))
        #expect(StudioEntityLink.parse(destination: "foreverlm://project/p%20q") == .notebook("p q"), "the address before the rename still reads")
        #expect(StudioEntityLink.parse(destination: "https://foreverlm.invalid/doc/abc-1") == .doc("abc-1"))
        #expect(StudioEntityLink.parse(destination: "https://foreverlm.invalid/notebook/p1") == .notebook("p1"))
        let runtime = try #require(URL(string: "\(ForeverLMRuntimeIdentity.urlScheme)://doc/d2"))
        #expect(StudioEntityLink.parse(runtime) == .doc("d2"))
    }

    @Test("A chat link is what the sidebar's Copy Link copies, and it parses back to the chat")
    func chatLinkRoundTrips() throws {
        let link = StudioEntityLink.chat("7F1C-session")
        #expect(link.markdownDestination == "foreverlm://chat/7F1C-session")
        #expect(StudioEntityLink.parse(destination: link.markdownDestination) == link)
        #expect(StudioEntityLink.parse(destination: "https://foreverlm.invalid/chat/c1") == .chat("c1"))
        let runtime = try #require(URL(string: "\(ForeverLMRuntimeIdentity.urlScheme)://chat/c2"))
        #expect(StudioEntityLink.parse(runtime) == .chat("c2"))
        #expect(link.markdown(title: "Measuring [MMP]") == "[Measuring \\[MMP\\]](foreverlm://chat/7F1C-session)")
        #expect(StudioEntityLink.parse(destination: "foreverlm://chat/") == nil)
    }

    @Test("A course quiz's link parses back to the quiz")
    func quizLinkRoundTrips() throws {
        let link = StudioEntityLink.quiz("cq-3f2a")
        #expect(link.markdownDestination == "foreverlm://quiz/cq-3f2a")
        #expect(link.kind == "quiz")
        #expect(StudioEntityLink.parse(destination: link.markdownDestination) == link)
        let runtime = try #require(URL(string: "\(ForeverLMRuntimeIdentity.urlScheme)://quiz/cq-9"))
        #expect(StudioEntityLink.parse(runtime) == .quiz("cq-9"))
        #expect(StudioEntityLink.parse(destination: "foreverlm://quiz/") == nil)
    }

    @Test("Sources, grounding, attachments and web links are not entity links")
    func rejectsOtherAddresses() {
        #expect(StudioEntityLink.parse(destination: "foreverlm://source/s1") == nil)
        #expect(StudioEntityLink.parse(destination: "https://foreverlm.invalid/grounding/s1,s2") == nil)
        #expect(StudioEntityLink.parse(destination: "foreverlm://attachment/img.png") == nil)
        #expect(StudioEntityLink.parse(destination: "https://example.com/doc/abc") == nil)
        #expect(StudioEntityLink.parse(destination: "foreverlm://doc/") == nil)
        #expect(StudioEntityLink.parse(destination: "foreverlm://doc") == nil)
    }

    @Test("The Markdown a drop writes carries the title and survives brackets in it")
    func writesMarkdown() {
        #expect(StudioEntityLink.doc("d1").markdown(title: "Reading notes") == "[Reading notes](foreverlm://doc/d1)")
        #expect(StudioEntityLink.notebook("p1").markdown(title: "Aging [2026]") == "[Aging \\[2026\\]](foreverlm://notebook/p1)")
        #expect(StudioEntityLink.notebook("p1").markdown(title: "  ") == "[Notebook](foreverlm://notebook/p1)")
        #expect(StudioEntityLink.parse(destination: StudioEntityLink.doc("a b").markdownDestination) == .doc("a b"))
    }
}
