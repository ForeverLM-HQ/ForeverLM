// MCPDataStoreTests: a page's comments over MCP.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

// MARK: - A page's comments over MCP

extension MCPDataStoreTests {
    @Test("Comment tools: a thread on a quote signed Assistant, a reply, resolve, edit, delete, and a team page refused")
    func mcpDocComments() async throws {
        let (store, path) = try TestStores.mcp()
        defer { cleanup(path) }
        let created = try parseJSON(try await store.createArtifact(
            title: "Cells",
            homeNotebookID: nil,
            notebookIDs: [],
            markdown: "# Cells\n\nThe cell makes energy from food."
        ))
        let docID = try #require((created["doc"] as? [String: Any])?["id"] as? String)

        let started = try parseJSON(try await store.commentOnDoc(artifactID: docID, quote: "makes energy", body: " Which pathway? ", replyTo: nil))
        let threadID = try #require(started["comment_id"] as? String)
        let replied = try parseJSON(try await store.commentOnDoc(artifactID: nil, quote: nil, body: "Oxidative phosphorylation.", replyTo: threadID))
        #expect(replied["thread_id"] as? String == threadID)

        var listed = try parseJSON(try await store.listDocComments(artifactID: docID))
        #expect(listed["open_count"] as? Int == 1)
        var threads = try #require(listed["threads"] as? [[String: Any]])
        #expect(threads.first?["quote"] as? String == "makes energy")
        var messages = try #require(threads.first?["messages"] as? [[String: Any]])
        #expect(messages.map { $0["body"] as? String } == ["Which pathway?", "Oxidative phosphorylation."])
        #expect(messages.allSatisfy { $0["by_assistant"] as? Bool == true && $0["author"] as? String == "Assistant" })

        _ = try await store.updateDocComment(commentID: threadID, body: "Which pathway, exactly?", resolved: true)
        listed = try parseJSON(try await store.listDocComments(artifactID: docID, includeResolved: false))
        #expect((listed["threads"] as? [[String: Any]])?.isEmpty == true)
        #expect(listed["resolved_count"] as? Int == 1)
        listed = try parseJSON(try await store.listDocComments(artifactID: docID))
        threads = try #require(listed["threads"] as? [[String: Any]])
        #expect(threads.first?["resolved"] as? Bool == true)
        messages = try #require(threads.first?["messages"] as? [[String: Any]])
        #expect(messages.first?["body"] as? String == "Which pathway, exactly?")

        // The first comment goes; its reply carries the thread on.
        let deleted = try parseJSON(try await store.deleteDocComment(commentID: threadID, wholeThread: false))
        #expect(deleted["deleted"] as? [String] == [threadID])
        threads = try #require(try parseJSON(try await store.listDocComments(artifactID: docID))["threads"] as? [[String: Any]])
        #expect(threads.count == 1)
        #expect(threads.first?["quote"] as? String == "makes energy")
        let heir = try #require(threads.first?["comment_id"] as? String)
        _ = try await store.deleteDocComment(commentID: heir, wholeThread: true)
        #expect((try parseJSON(try await store.listDocComments(artifactID: docID))["threads"] as? [[String: Any]])?.isEmpty == true)

        await #expect(throws: MCPError.self) {
            _ = try await store.commentOnDoc(artifactID: docID, quote: nil, body: "No quote", replyTo: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.updateDocComment(commentID: "missing", body: nil, resolved: true)
        }

        // A team's page takes no comments over MCP.
        let team = try await createdTeamPage(store, markdown: "# Team\n\nThe team's words.")
        do {
            _ = try await store.commentOnDoc(artifactID: team.artifact.id, quote: "team's words", body: "Hi", replyTo: nil)
            Issue.record("a team page took a comment")
        } catch {
            #expect(error.localizedDescription.contains("team's page"), "\(error.localizedDescription)")
        }
    }
}
