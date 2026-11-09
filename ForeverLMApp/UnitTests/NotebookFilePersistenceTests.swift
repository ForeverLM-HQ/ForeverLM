import AppKit
import Foundation
import PDFKit
import Testing
@testable import ForeverLM

@Suite("Notebook File Persistence")
struct NotebookFilePersistenceTests {
    @Test("Merging a Notebook moves its workspace files into the survivor, keeping both copies of a shared name")
    func mergingNotebooksMovesWorkspaceFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookMergeFilesTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let survivor = try await storage.createCompanionGoal(
            title: "Mito Phenotyping",
            topic: "mito phenotyping",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let merged = try await storage.createCompanionGoal(
            title: "Mitochondria",
            topic: "mitochondria",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        for (notebookID, body) in [(survivor.id, "Survivor notes"), (merged.id, "Merged notes")] {
            let created = try await storage.createNotebookMarkdownFile(notebookID: notebookID, preferredRelativePath: "Notes.md")
            _ = try await storage.writeNotebookMarkdownFile(
                notebookID: notebookID,
                relativePath: "Notes.md",
                markdown: body,
                expectedRevision: created.revision
            )
        }
        let only = try await storage.createNotebookMarkdownFile(notebookID: merged.id, preferredRelativePath: "Drafts/Only here.md")
        _ = try await storage.writeNotebookMarkdownFile(
            notebookID: merged.id,
            relativePath: "Drafts/Only here.md",
            markdown: "Only in the merged notebook",
            expectedRevision: only.revision
        )
        let mergedWorkspace = try await storage.notebookWorkspaceURL(notebookID: merged.id, createIfNeeded: false)

        let result = try await storage.mergeCompanionGoals(notebookIDs: [survivor.id, merged.id])

        #expect(result.filesMoved == 2)
        let files = try await storage.loadNotebookFiles(notebookID: survivor.id).map(\.notebookRelativePath)
        #expect(files.sorted() == ["Drafts/Only here.md", "From Mitochondria/Notes.md", "Notes.md"])
        let kept = try await storage.notebookMarkdownFile(notebookID: survivor.id, relativePath: "Notes.md")
        #expect(kept.markdown == "Survivor notes")
        let adopted = try await storage.notebookMarkdownFile(notebookID: survivor.id, relativePath: "From Mitochondria/Notes.md")
        #expect(adopted.markdown == "Merged notes")
        #expect(!FileManager.default.fileExists(atPath: mergedWorkspace.path))
        // The merged notebook stays as a redirect row (schema v2 5.2), so its path still resolves,
        // and nothing is there: its files all moved.
        let stub = try await storage.notebookWorkspaceURL(notebookID: merged.id, createIfNeeded: false)
        #expect(!FileManager.default.fileExists(atPath: stub.path))
    }

    @Test("Markdown artifacts can be created and revision-safely edited")
    func markdownArtifactsAreEditable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookMarkdownTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageService(storeRoot: root)
        let notebook = try await storage.createCompanionGoal(
            title: "Article notebook",
            topic: "writing",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        let created = try await storage.createNotebookMarkdownFile(
            notebookID: notebook.id,
            preferredRelativePath: "Drafts/Article.md"
        )
        #expect(created.record.notebookRelativePath == "Drafts/Article.md")
        #expect(created.markdown.isEmpty)

        let firstRevision = try await storage.writeNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Drafts/Article.md",
            markdown: "# First draft\n\nA grounded argument.",
            expectedRevision: created.revision
        )
        #expect(firstRevision.markdown.contains("A grounded argument."))
        #expect(firstRevision.revision != created.revision)

        let context = try await storage.notebookMaterialContext(notebookID: notebook.id)
        #expect(context.contains("### Drafts/Article.md"))
        #expect(context.contains("A grounded argument."))

        do {
            _ = try await storage.writeNotebookMarkdownFile(
                notebookID: notebook.id,
                relativePath: "Drafts/Article.md",
                markdown: "This must not overwrite the newer draft.",
                expectedRevision: created.revision
            )
            Issue.record("Expected a stale Markdown revision to fail")
        } catch let error as NotebookMarkdownFileError {
            #expect(error == .conflict("Drafts/Article.md"))
        }

        let preserved = try await storage.notebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: "Drafts/Article.md"
        )
        #expect(preserved.markdown == "# First draft\n\nA grounded argument.")
    }

    @Test("Preserves arbitrary user folders and rebuilds the SQLite projection")
    func importsAndReconcilesNotebookFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookFileTests_\(UUID().uuidString)", isDirectory: true)
        let importRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookFileImports_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: importRoot)
        }

        let storage = StorageService(storeRoot: root)
        let now = Date()
        let notebook = try await storage.createCompanionGoal(
            title: "GFP analysis",
            topic: "GFP",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let sourceDirectory = importRoot.appendingPathComponent("challenge data", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("brightness.tsv")
        try Data("sequence\tbrightness\nAAA\t1.5\nBBB\t2.0\n".utf8).write(to: sourceURL)

        let imported = try await storage.importNotebookFiles(
            notebookID: notebook.id,
            urls: [sourceDirectory]
        )
        #expect(imported.count == 1)
        #expect(imported[0].relativePath == "Projects/\(notebook.id)/challenge data/brightness.tsv")
        #expect(imported[0].notebookRelativePath == "challenge data/brightness.tsv")
        let workspace = try await storage.notebookWorkspaceURL(notebookID: notebook.id)
        let topLevelNames = try FileManager.default.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(topLevelNames == ["challenge data"])

        let rebuilt = try await storage.loadNotebookFiles(notebookID: notebook.id)
        #expect(rebuilt == imported)
        let destination = await storage.notebookFileURL(for: imported[0])
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let preview = try await storage.notebookFilePreview(for: imported[0])
        guard case .table(let table) = preview else {
            Issue.record("Expected a table preview")
            return
        }
        #expect(table.columns == ["sequence", "brightness"])
        #expect(table.rows == [["AAA", "1.5"], ["BBB", "2.0"]])
    }

    @Test("Notebook preview reads cells and saved outputs without executing code")
    func notebookPreviewIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookTests_\(UUID().uuidString)", isDirectory: true)
        let importRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookImports_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: importRoot)
        }

        let storage = StorageService(storeRoot: root)
        let now = Date()
        let notebook = try await storage.createCompanionGoal(
            title: "Notebook",
            topic: "Notebook",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let notebookURL = importRoot.appendingPathComponent("analysis.ipynb")
        let notebookJSON = """
        {
          "metadata": {"kernelspec": {"display_name": "Python 3"}},
          "cells": [
            {"cell_type": "markdown", "source": ["# Result\\n", "A summary."]},
            {
              "cell_type": "code",
              "execution_count": 4,
              "source": ["print('saved')"],
              "outputs": [{"output_type": "stream", "text": ["saved\\n"]}]
            }
          ],
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """
        try Data(notebookJSON.utf8).write(to: notebookURL)
        let records = try await storage.importNotebookFiles(
            notebookID: notebook.id,
            urls: [notebookURL]
        )

        let preview = try await storage.notebookFilePreview(for: records[0])
        guard case .notebook(let parsed) = preview else {
            Issue.record("Expected a notebook preview")
            return
        }
        #expect(parsed.kernelName == "Python 3")
        #expect(parsed.cells.count == 2)
        #expect(parsed.cells[0].kind == .markdown)
        #expect(parsed.cells[1].source == "print('saved')")
        #expect(parsed.cells[1].outputs == [.text(id: 10_000, content: "saved\n")])
    }

    @Test("Every Notebook file becomes context without becoming a library source")
    func notebookFilesBecomeContextWithoutSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookMaterialTests_\(UUID().uuidString)", isDirectory: true)
        let importRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookMaterialImports_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: importRoot)
        }

        let storage = StorageService(storeRoot: root)
        let notebook = try await storage.createCompanionGoal(
            title: "Computational biology take-home",
            topic: "viral vector design",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let requirementsDirectory = importRoot.appendingPathComponent("Take-home", isDirectory: true)
        try FileManager.default.createDirectory(at: requirementsDirectory, withIntermediateDirectories: true)
        let briefURL = requirementsDirectory.appendingPathComponent("CB challenge description.pdf")
        let requirement = "Rank every candidate design using the validation data before selecting the final construct."
        try writeSearchablePDF(
            """
            Computational Biology Challenge Description
            This notebook asks the analyst to compare candidate constructs, measure their behavior,
            explain the biological mechanism, and communicate every assumption with supporting evidence.
            \(requirement)
            The final submission must include reproducible analysis and a concise technical summary.
            """,
            to: briefURL
        )
        let backgroundDirectory = importRoot.appendingPathComponent("Background reading", isDirectory: true)
        try FileManager.default.createDirectory(at: backgroundDirectory, withIntermediateDirectories: true)
        let referenceURL = backgroundDirectory.appendingPathComponent("Sarkisyan 2016.pdf")
        let evidence = "Local fitness landscapes constrain the accessible paths between fluorescent protein variants."
        // Long enough that the PDF's own text is read: a page of a dozen words
        // is taken for a scan and read by OCR, which now and then drops a line.
        let filler = String(repeating: "Further measurements of each variant follow in the supplementary tables. ", count: 4)
        try writeSearchablePDF(evidence + " " + filler, to: referenceURL)
        let inputsDirectory = importRoot.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
        let dataURL = inputsDirectory.appendingPathComponent("raw observations.tsv")
        let rawDataMarker = "candidate_17\t0.942"
        try Data("candidate\tscore\n\(rawDataMarker)\n".utf8).write(to: dataURL)
        _ = try await storage.importNotebookFiles(
            notebookID: notebook.id,
            urls: [requirementsDirectory, backgroundDirectory, inputsDirectory]
        )

        let context = try await storage.notebookMaterialContext(notebookID: notebook.id)
        #expect(context.contains("## Notebook files"))
        #expect(context.contains("### Take-home/CB challenge description.pdf"))
        #expect(context.contains("### Background reading/Sarkisyan 2016.pdf"))
        #expect(context.contains("### Inputs/raw observations.tsv"))
        let normalizedContext = context.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        #expect(normalizedContext.contains(requirement))
        #expect(normalizedContext.contains(evidence))
        #expect(context.contains(rawDataMarker))

        let notebookFiles = try await storage.loadNotebookFiles(notebookID: notebook.id)
        #expect(notebookFiles.count == 3)
        for record in notebookFiles {
            let url = await storage.notebookFileURL(for: record)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try await storage.loadActiveSources().isEmpty)
    }

    private func writeSearchablePDF(_ text: String, to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NotebookFileTestError.renderFailed
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSString(string: text).draw(
            in: CGRect(x: 54, y: 100, width: 504, height: 620),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.black,
            ]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    private enum NotebookFileTestError: Error {
        case renderFailed
    }
}
