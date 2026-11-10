// MCPToolRegistry: runs the Doc, Page, site, animation and notebook-file tools; one topic's share of `executeTool`.
import Foundation

extension MCPToolRegistry {

    /// Runs one of the Doc, Page, site, animation and notebook-file tools; nil for any other name.
    func executePagesTool(name: String, arguments: [String: Any], hostSessionID: String?, access: MCPAccessContext) async throws -> String? {
        switch name {
        case "list_docs":
            return try await store.listArtifacts(notebookID: arguments["notebook_id"] as? String)
        case "create_doc":
            return try await store.createArtifact(
                title: arguments["title"] as? String ?? "",
                homeNotebookID: arguments["home_notebook_id"] as? String,
                notebookIDs: arguments["notebook_ids"] as? [String] ?? [],
                markdown: arguments["markdown"] as? String ?? "",
                isDraft: arguments["is_draft"] as? Bool ?? false
            )
        case "read_doc":
            return try await store.readArtifact(
                artifactID: arguments["doc_id"] as? String ?? "",
                start: arguments["start"] as? Int,
                length: arguments["length"] as? Int,
                resolveReferences: arguments["resolve_references"] as? Bool ?? false
            )
        case "list_doc_chats":
            return try await store.listArtifactChats(
                artifactID: arguments["doc_id"] as? String ?? ""
            )
        case "link_doc_passage_to_chat":
            return try await store.linkArtifactPassageToChat(
                artifactID: arguments["doc_id"] as? String ?? "",
                sessionID: MCPDataStore.reviewSessionID(from: arguments["session_id"]),
                quote: arguments["quote"] as? String ?? "",
                sectionTitle: arguments["section_title"] as? String ?? ""
            )
        case "unlink_doc_chat":
            return try await store.unlinkArtifactChat(
                linkID: arguments["link_id"] as? String ?? ""
            )
        case "list_doc_comments":
            return try await store.listDocComments(
                artifactID: arguments["doc_id"] as? String ?? "",
                includeResolved: arguments["include_resolved"] as? Bool ?? true
            )
        case "comment_on_doc":
            return try await store.commentOnDoc(
                artifactID: arguments["doc_id"] as? String,
                quote: arguments["quote"] as? String,
                body: arguments["body"] as? String ?? "",
                replyTo: arguments["reply_to"] as? String
            )
        case "update_doc_comment":
            return try await store.updateDocComment(
                commentID: arguments["comment_id"] as? String ?? "",
                body: arguments["body"] as? String,
                resolved: arguments["resolved"] as? Bool
            )
        case "delete_doc_comment":
            return try await store.deleteDocComment(
                commentID: arguments["comment_id"] as? String ?? "",
                wholeThread: arguments["whole_thread"] as? Bool ?? false
            )
        case "write_doc":
            return try await store.writeArtifact(
                artifactID: arguments["doc_id"] as? String ?? "",
                markdown: arguments["markdown"] as? String ?? "",
                expectedRevision: arguments["expected_revision"] as? String ?? "",
                publish: arguments["publish"] as? Bool ?? false
            )
        case "edit_doc":
            let rawEdits = arguments["edits"] as? [[String: Any]] ?? []
            let edits = rawEdits.map { edit in
                MCPDataStore.ArtifactEdit(
                    find: edit["find"] as? String ?? "",
                    replace: edit["replace"] as? String ?? "",
                    replaceAll: edit["replace_all"] as? Bool ?? false
                )
            }
            return try await store.editArtifact(
                artifactID: arguments["doc_id"] as? String ?? "",
                edits: edits,
                append: arguments["append"] as? String,
                expectedRevision: arguments["expected_revision"] as? String ?? "",
                publish: arguments["publish"] as? Bool ?? false
            )
        case "update_doc":
            return try await store.updateArtifact(
                artifactID: arguments["doc_id"] as? String ?? "",
                title: arguments["title"] as? String,
                homeNotebookID: arguments["home_notebook_id"] as? String,
                notebookIDs: arguments["notebook_ids"] as? [String],
                isDraft: arguments["is_draft"] as? Bool,
                isArchived: arguments["is_archived"] as? Bool,
                isHidden: arguments["is_hidden"] as? Bool
            )
        case "delete_doc":
            return try await store.deleteArtifact(artifactID: arguments["doc_id"] as? String ?? "")
        case "list_doc_versions":
            return try await store.listDocVersions(
                artifactID: arguments["doc_id"] as? String ?? "",
                versionID: arguments["version_id"] as? String,
                start: arguments["start"] as? Int,
                length: arguments["length"] as? Int
            )
        case "restore_doc_version":
            return try await store.restoreDocVersion(
                artifactID: arguments["doc_id"] as? String ?? "",
                versionID: arguments["version_id"] as? String ?? "",
                expectedRevision: arguments["expected_revision"] as? String,
                publish: arguments["publish"] as? Bool ?? false
            )
        case "list_spaces":
            return try await store.listPageSpaces()
        case "update_space":
            return try await store.updatePageSpace(
                action: arguments["action"] as? String ?? "",
                spaceID: arguments["space_id"] as? String,
                name: arguments["name"] as? String,
                docIDs: arguments["doc_ids"] as? [String]
            )
        case "link_page", "link_google_doc":
            return try await store.linkPageArtifact(
                urlString: arguments["url"] as? String ?? "",
                title: arguments["title"] as? String,
                text: arguments["text"] as? String,
                homeNotebookID: arguments["home_notebook_id"] as? String,
                notebookIDs: arguments["notebook_ids"] as? [String] ?? []
            )
        case "unlink_page", "unlink_google_doc":
            return try await store.unlinkPageArtifact(artifactID: arguments["doc_id"] as? String ?? "")
        case "adopt_page":
            return try await store.adoptPageArtifact(
                artifactID: arguments["doc_id"] as? String ?? "",
                markdown: arguments["markdown"] as? String,
                readers: arguments["readers"] as? [String],
                slug: arguments["slug"] as? String
            )
        case "publish_doc":
            if arguments["password"] != nil {
                throw MCPError.invalidInput("Pages are no longer shared with a password. Pass readers, a list of email addresses, instead.")
            }
            return try await store.publishArtifact(
                artifactID: arguments["doc_id"] as? String ?? "",
                readers: arguments["readers"] as? [String],
                slug: arguments["slug"] as? String
            )
        case "unpublish_doc":
            return try await store.unpublishArtifact(artifactID: arguments["doc_id"] as? String ?? "")
        case "save_site":
            return try await store.saveSite(
                site: arguments["site"] as? String,
                title: arguments["title"] as? String,
                html: arguments["html"] as? String,
                files: arguments["files"] as? [Any],
                repository: arguments["repository"] as? String,
                repositoryPath: arguments["repository_path"] as? String,
                ref: arguments["ref"] as? String,
                removeFiles: arguments["remove_files"] as? [String] ?? [],
                replaceAll: arguments["replace_all"] as? Bool ?? false,
                homeNotebookID: arguments["home_notebook_id"] as? String,
                notebookIDs: arguments["notebook_ids"] as? [String] ?? []
            )
        case "read_site_file":
            return try await store.readSiteFile(
                site: arguments["site"] as? String ?? "",
                path: arguments["path"] as? String
            )
        case "replace_site_text":
            return try await store.replaceSiteText(
                site: arguments["site"] as? String ?? "",
                find: arguments["find"] as? String ?? "",
                replace: arguments["replace"] as? String ?? "",
                path: arguments["path"] as? String
            )
        case "save_animation":
            return try await store.saveAnimation(
                animation: arguments["animation"] as? String,
                title: arguments["title"] as? String,
                description: arguments["description"] as? String,
                html: arguments["html"] as? String,
                files: arguments["files"] as? [Any],
                sources: arguments["sources"] as? [String] ?? [],
                removeFiles: arguments["remove_files"] as? [String] ?? [],
                replaceAll: arguments["replace_all"] as? Bool ?? false,
                homeNotebookID: arguments["home_notebook_id"] as? String,
                notebookIDs: arguments["notebook_ids"] as? [String] ?? []
            )
        case "list_animations":
            return try await store.listAnimations(
                sourceID: arguments["source_id"] as? String,
                notebookID: arguments["notebook_id"] as? String
            )
        case "delete_animation":
            return try await store.deleteAnimation(animation: arguments["animation"] as? String ?? "")
        case "list_source_artifacts":
            return try await store.listSourceArtifacts(sourceID: arguments["source_id"] as? String ?? "")
        case "read_notebook_markdown_file":
            return try await store.readNotebookMarkdownFile(
                notebookID: arguments["notebook_id"] as? String,
                relativePath: arguments["path"] as? String ?? ""
            )
        case "write_notebook_markdown_file":
            return try await store.writeNotebookMarkdownFile(
                notebookID: arguments["notebook_id"] as? String,
                relativePath: arguments["path"] as? String ?? "",
                markdown: arguments["markdown"] as? String ?? "",
                expectedRevision: arguments["expected_revision"] as? String
            )
        case "list_open_questions":
            return try store.listOpenQuestions(
                notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                includeResolved: arguments["include_resolved"] as? Bool,
                status: arguments["status"] as? String
            )
        case "create_open_question":
            return try store.createOpenQuestion(
                notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                summary: arguments["summary"] as? String ?? "",
                sourceID: arguments["source_id"] as? String,
                severity: clampUnitInterval(optional: arguments["severity"] as? Double),
                status: arguments["status"] as? String
            )
        case "update_open_question":
            return try store.updateOpenQuestion(
                notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                questionID: arguments["question_id"] as? String ?? "",
                summary: arguments["summary"] as? String,
                sourceID: arguments["source_id"] as? String,
                severity: clampUnitInterval(optional: arguments["severity"] as? Double),
                status: arguments["status"] as? String,
                clearSourceID: arguments["clear_source_link"] as? Bool ?? false
            )
        case "update_notebook_notes", "append_notebook_notes":
            return try store.updateNotebookNotes(
                notebookID: arguments["notebook_id"] as? String,
                markdown: arguments["markdown"] as? String ?? arguments["notes"] as? String ?? "",
                append: name == "append_notebook_notes"
            )
        case "split_notebook":
            return try store.splitNotebook(
                notebookID: arguments["notebook_id"] as? String ?? arguments["goal_id"] as? String,
                splits: arguments["splits"] as? [[String: Any]] ?? [],
                keepParent: arguments["keep_parent"] as? Bool ?? true
            )
        case "merge_notebooks":
            return try store.mergeNotebooks(
                notebookIDs: arguments["notebook_ids"] as? [String] ?? [],
                title: arguments["title"] as? String,
                mergeNotes: arguments["merge_notes"] as? Bool ?? true
            )
        default:
            return nil
        }
    }
}
