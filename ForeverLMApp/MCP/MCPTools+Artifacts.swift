import Foundation

extension MCPDataStore {
    func listArtifacts(notebookID: String?) async throws -> String {
        if let notebookID, !notebookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try resolveMCPNotebookGoal(notebookID: notebookID, store: knowledgeStore())
        }
        let normalizedNotebookID = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Screen record mode (admin only): what the take made, or what is
        // filed under the recording Notebook.
        let screenScope = screenRecordScope()
        let artifacts = try await notebookFileStorage.loadArtifacts(
            notebookID: normalizedNotebookID?.isEmpty == false ? normalizedNotebookID : nil
        ).filter { artifact in
            screenScope.map { screenRecordAllowsArtifact(artifact, scope: $0) } ?? true
        }
        // Publication is owner-scoped server state, not Artifact metadata. A
        // failed/offline status projection must never hide the local Docs list.
        let published: [String: PublishedDocStatus]
        do {
            published = try await DocPublishing.statuses()
        } catch DocPublishingError.signedOut {
            published = [:]
        } catch {
            logger.error("Reading the Docs' publication status failed: \(error.localizedDescription, privacy: .public)")
            published = [:]
        }
        // The teams holding a copy of each own Doc, for the sentence the app's
        // Share popover says (`DocSharing.summary`). Asked only when there are
        // teams at all; a team's own copy is not shared onward.
        let store = try knowledgeStore()
        let hasTeams = !((try? store.loadTeams()) ?? []).isEmpty
        // An audio overview by its kind, or by its script source when an
        // older build saved the record back without the kind.
        let overviewIDs = Set(try artifacts.filter { try store.isAudioOverview($0) }.map(\.id))
        // The learner's spaces of pages (list_spaces), one read of the rows.
        let spaces = PageSpaceRows.read()
        return try jsonString([
            "scope": normalizedNotebookID?.isEmpty == false ? "notebook" : "global",
            "notebook_id": normalizedNotebookID?.isEmpty == false
                ? normalizedNotebookID.map { $0 as Any } ?? NSNull()
                : NSNull(),
            "doc_count": artifacts.count,
            "docs": artifacts.map { artifact in
                var payload = artifactPayload(artifact, isAudioOverview: overviewIDs.contains(artifact.id))
                let status = published[artifact.id]
                if let status {
                    payload["published"] = true
                    payload["published_url"] = status.url.absoluteString
                    payload["published_slug"] = status.slug
                    payload["published_restricted"] = status.isProtected
                    if !status.readers.isEmpty { payload["published_readers"] = status.readers }
                    // Legacy: a page still guarded by a password from before reader lists.
                    if let password = status.password { payload["published_password"] = password }
                } else {
                    payload["published"] = false
                }
                let teamNames = hasTeams && artifact.teamID == nil
                    ? ((try? store.teamsHoldingArtifact(artifact.id)) ?? []).map(\.name)
                    : []
                payload["published_access_summary"] = DocSharing.summary(status: status, teamNames: teamNames)
                let space = spaces.space(ofPage: artifact.id)
                payload["space_id"] = space.map { $0.id as Any } ?? NSNull()
                payload["space_name"] = space.map { $0.name as Any } ?? NSNull()
                return payload
            },
            "guidance": "Each Doc is one canonical Markdown document. A published Doc opens as its rendered page in ForeverLM; Markdown remains its editable source. published_url, published_restricted and published_readers describe its live site, and published_access_summary says who can open it in the sentence the app's Share popover shows (change it with publish_doc's readers, an empty list for anyone with the link, and share_with_team). Read it with read_doc, then pass the returned revision to write_doc. Notebook links organize access and never create copies. space_id and space_name name the learner's space of pages the Doc is in (list_spaces, update_space), null when it is in none. A Doc with kind google_doc, claude_artifact, codex_site or foreverlm_site is a linked page: read_doc returns ForeverLM's read-only text copy and linked_url, and write_doc refuses it — edits belong in the product that owns the page, or in save_site for a ForeverLM site. A record with kind animation is an animation (section animations): a moving explanation kept in the library at linked_url and linked to the sources in source_ids; change it with save_animation, list them with list_animations. In the app a Google Doc sits in Pages beside the Markdown pages, and a Claude artifact, a Codex site or a ForeverLM site sits in Sites — the home's Pages tab lists both; an animation is listed in the Space's Animations place and in its Notebook's Studio, and a chat that saves one plays it as a card under the reply, and a mnemonic reading only in its Notebook (its Studio and its Pages; one in no notebook stays on the Pages tab). A record with kind audio_overview is a Notebook's audio overview: its Markdown is only its recipe, write_doc, edit_doc and publish_doc refuse it, get_source_content with its audio_source_id reads the spoken script, and delete_doc deletes it with its script and audio. A record with kind mnemonic_reading is a mnemonic reading, its sources' own text read with recall questions in it: its Markdown is its questions, get_mnemonic_reading reads them with where each stands in the learner's Memory, and write_doc, edit_doc and publish_doc refuse it.",
        ] as [String: Any])
    }

    func createArtifact(
        title: String,
        homeNotebookID: String?,
        notebookIDs: [String],
        markdown: String,
        isDraft: Bool = false
    ) async throws -> String {
        let rendering = try await renderedDocPictures(in: markdown, alreadyIn: "")
        var snapshot = try await notebookFileStorage.createArtifact(
            title: title,
            homeNotebookID: homeNotebookID,
            linkedNotebookIDs: notebookIDs,
            markdown: rendering.pictures.isEmpty ? markdown : "",
            isDraft: isDraft
        )
        var kept = 0
        if !rendering.pictures.isEmpty {
            // The pictures are kept in the new Doc's own folder, which exists
            // once the Doc does; the body that names them follows.
            let id = snapshot.artifact.id
            do {
                let body = try await notebookFileStorage.keepDocPictures(rendering.pictures, in: markdown, artifactID: id)
                kept = body.kept
                snapshot = try await notebookFileStorage.writeArtifactMarkdownAndSync(
                    artifactID: id,
                    markdown: body.markdown,
                    expectedRevision: snapshot.revision
                )
            } catch {
                do {
                    try await notebookFileStorage.deleteArtifact(id)
                } catch let cleanupError {
                    logger.error("Removing the half-written Doc failed: \(cleanupError.localizedDescription, privacy: .public)")
                }
                throw error
            }
        }
        var payload: [String: Any] = [
            "doc": artifactPayload(snapshot.artifact),
            "revision": snapshot.revision,
            "message": "Created Doc ‘\(snapshot.artifact.title)’.",
        ]
        Self.notePictures(&payload, kept: kept, notShown: [])
        return try jsonString(payload)
    }

    /// Renders the picture lines a Doc write carries — `![…](foreverlm://image/…)`,
    /// the lines show_source_image, inspect_paper_figure, generate_image and
    /// list_images return — so the write can keep each as the Doc's own
    /// attachment (`StorageService.renderDocPictures`). A Doc draws only
    /// pictures it keeps; before this, every such line drew as a broken-picture
    /// box (product owner, 2026-09-29, a walkthrough Doc's 25 slides and a white
    /// paper Doc's 3 figures).
    ///
    /// A picture this Mac cannot render refuses the write and names why, so no
    /// Doc is saved with a picture it cannot show. A line the Doc already
    /// carried (`current`) never blocks an edit elsewhere in it: it stays as
    /// it was and the result says so.
    private func renderedDocPictures(in markdown: String, alreadyIn current: String) async throws -> DocPictureRendering {
        guard !DocPictureLines.addresses(in: markdown).isEmpty else { return DocPictureRendering() }
        let rendering = await notebookFileStorage.renderDocPictures(in: markdown)
        let blocking = rendering.failures.filter { !current.contains($0.address) }
        guard blocking.isEmpty else {
            let lines = blocking.map { "- \($0.address): \($0.reason)." }.joined(separator: "\n")
            throw MCPError.invalidInput(
                "Nothing was saved. A Doc keeps its own copy of every picture it shows, and \(blocking.count == 1 ? "this picture" : "these pictures") could not be drawn on the learner's Mac:\n\(lines)\nUse each picture line exactly as show_source_image, inspect_paper_figure, generate_image or list_images returned it (for a video whose slides were never captured, call extract_video_slides first), or leave the line out."
            )
        }
        return rendering
    }

    /// Tells the caller what became of the Doc's picture lines.
    private static func notePictures(_ payload: inout [String: Any], kept: Int, notShown: [DocPictureFailure]) {
        if kept > 0 {
            payload["pictures_kept"] = kept
            payload["pictures_note"] = "Each picture line now names the Doc's own copy of the picture (foreverlm://attachment/…), which travels with the Doc; read_doc returns it that way. Pass those lines back unchanged."
        }
        if !notShown.isEmpty {
            payload["pictures_not_shown"] = notShown.map { ["address": $0.address, "reason": $0.reason] }
            payload["pictures_not_shown_guidance"] = "These picture lines were already in the Doc and still draw as a broken picture. Replace each with a line show_source_image or inspect_paper_figure returns, or remove it."
        }
    }

    func readArtifact(
        artifactID: String,
        start: Int? = nil,
        length: Int? = nil,
        resolveReferences: Bool = false
    ) async throws -> String {
        let snapshot: ArtifactMarkdownSnapshot
        do {
            snapshot = try await notebookFileStorage.artifactMarkdown(artifactID)
        } catch {
            // The doc_id generate_report answered with, for a report still
            // being written or one that never came: say which.
            if let message = await reportNotSavedMessage(artifactID) {
                throw MCPError.notFound(message)
            }
            throw error
        }
        // resolve_references: the body as a reader outside the app gets it,
        // references read as their words (docs/notes-graph-design.md).
        let body = resolveReferences
            ? try await notebookFileStorage.docGraphResolvedMarkdown(snapshot.markdown, teamID: snapshot.artifact.teamID)
            : snapshot.markdown
        let total = body.count
        let offset = start ?? 0
        guard offset >= 0, offset <= total else {
            throw MCPError.invalidInput("start must be between 0 and \(total).")
        }
        let requestedLength = length ?? (total - offset)
        // A length asked for is 1…50,000; without one the rest of the body
        // is read, which for an empty Doc (a day's new note) is nothing.
        guard length == nil || (1...50_000).contains(requestedLength) else {
            throw MCPError.invalidInput("length must be between 1 and 50000.")
        }
        let endOffset = min(total, offset + requestedLength)
        let lower = body.index(body.startIndex, offsetBy: offset)
        let upper = body.index(body.startIndex, offsetBy: endOffset)
        let excerpt = String(body[lower..<upper])
        let isOverview = AudioOverviewScript.isOverview(snapshot.artifact, markdown: snapshot.markdown)
        var payload: [String: Any] = [
            "doc": artifactPayload(snapshot.artifact, isAudioOverview: isOverview),
            "markdown": excerpt,
            "revision": snapshot.revision,
            "range_start": offset,
            "range_end": endOffset,
            "total_characters": total,
            "is_complete": offset == 0 && endOffset == total,
            "guidance": "Pass revision unchanged as expected_revision when replacing this Doc.",
        ]
        // An audio overview's body is its recipe; the script is its carrier
        // source's text. Read even when an older build saved the record back
        // without its kind, by the marker its body starts with.
        if isOverview, let settings = AudioOverviewScript.settings(fromMarkdown: snapshot.markdown) {
            payload["audio_overview"] = Self.audioOverviewSettingsPayload(settings)
            payload["audio_source_id"] = settings.audioSourceID
            payload["guidance"] = "This is a Notebook's audio overview. markdown is its recipe; get_source_content with audio_source_id reads the spoken script, get_source_audio_status follows its audio, and delete_doc deletes the overview with its script."
        }
        // A report (generate_report) closes with the recipe it was made from.
        if !isOverview, snapshot.artifact.kind == nil, !snapshot.artifact.isLinked,
           let recipe = ReportRecipe.parse(fromMarkdown: snapshot.markdown) {
            payload["report"] = Self.reportRecipePayload(recipe)
        }
        // A mnemonic reading's body is its questions, read even when an older
        // build saved the record back without its kind.
        if snapshot.artifact.isMnemonicReading(markdown: snapshot.markdown) {
            payload["guidance"] = "This is a mnemonic reading: markdown is its questions, each under the source it is asked in. get_mnemonic_reading reads them with where each stands in the learner's Memory, and answer_mnemonic_question records an answer; write_doc, edit_doc and publish_doc refuse it."
        }
        if let linkedURL = snapshot.artifact.linkedURL {
            payload["linked_url"] = linkedURL
            payload["read_only"] = true
            let kind = snapshot.artifact.linkedKind
            let label = kind?.label ?? "linked page"
            let owner = kind?.productName ?? "the product that owns it"
            payload["kind"] = kind?.rawValue ?? "linked"
            payload["guidance"] = total == 0
                ? "This Doc is a \(label) at linked_url. Its text copy is not available here yet — the page may need a \(owner) sign-in in ForeverLM, or has not been opened there since it was linked. To change the page, edit it in \(owner); write_doc and edit_doc refuse linked pages. If you can read the page yourself, call link_page again with the same url and its text to hand ForeverLM the copy now. adopt_page makes it ForeverLM's own published page in one call (pass its real Markdown if you have it); unlink_page turns it into an editable Doc without a page."
                : "This Doc is a \(label) at linked_url; markdown is ForeverLM's read-only text copy of it. To change the page, edit it in \(owner) — write_doc and edit_doc refuse linked pages — then call link_page again with the same url and the new text to refresh this copy at once (it also refreshes when the doc is opened in ForeverLM). adopt_page makes it ForeverLM's own published page in one call, editable here from then on (pass its real Markdown if you have it); unlink_page turns the copy into an editable Doc without a page."
        }
        if resolveReferences { Self.noteResolvedReferences(&payload) }
        return try jsonString(payload)
    }

    func writeArtifact(
        artifactID: String,
        markdown: String,
        expectedRevision: String,
        publish: Bool = false
    ) async throws -> String {
        try await refuseLinkedPageEdit(artifactID)
        let current = try await notebookFileStorage.artifactMarkdown(artifactID)
        try Self.refuseAudioOverviewChange(current, doing: "write_doc")
        try Self.refuseMnemonicReadingChange(current, doing: "write_doc")
        guard current.revision.caseInsensitiveCompare(expectedRevision) == .orderedSame else {
            // A whole body over a newer one would drop what changed since it
            // was read, so this one still refuses; edit_doc is the route that
            // applies to the newer text.
            throw MCPError.invalidInput(
                "Nothing was saved. ‘\(current.artifact.title)’ changed after you read it — the learner may be editing it right now — and write_doc replaces the whole body, which would drop those changes. Change the passages you mean with edit_doc, which applies to the newest text, or call read_doc again and write from the revision it returns."
            )
        }
        let rendering = try await renderedDocPictures(in: markdown, alreadyIn: current.markdown)
        let body = try await notebookFileStorage.keepDocPictures(rendering.pictures, in: markdown, artifactID: artifactID)
        let snapshot = try await notebookFileStorage.writeArtifactMarkdownAndSync(
            artifactID: artifactID,
            markdown: body.markdown,
            expectedRevision: expectedRevision,
            versionReason: .assistantEdit
        )
        var payload: [String: Any] = [
            "doc": artifactPayload(snapshot.artifact),
            "revision": snapshot.revision,
            "message": "Saved Doc ‘\(snapshot.artifact.title)’ for every linked Notebook.",
        ]
        Self.notePictures(&payload, kept: body.kept, notShown: rendering.failures)
        await finishPublishedPage(&payload, snapshot: snapshot, republish: publish)
        return try jsonString(payload)
    }

    /// An audio overview's body is its recipe, which its row, `read_doc` and
    /// a remake read; its script is a source of its own. Neither a new body
    /// nor a published page of the recipe means anything, so the Docs write
    /// tools refuse one — read even when an older build dropped the kind, by
    /// the marker its body starts with.
    static func refuseAudioOverviewChange(_ snapshot: ArtifactMarkdownSnapshot, doing tool: String) throws {
        guard AudioOverviewScript.isOverview(snapshot.artifact, markdown: snapshot.markdown) else { return }
        throw MCPError.invalidInput(
            "‘\(snapshot.artifact.title)’ is a Notebook's audio overview, which \(tool) does not change: its Markdown is the recipe it was made from. Its spoken script is the source audio_source_id names (read_doc returns it; get_source_content reads it). To change what it says, make a new one with generate_audio_overview; update_doc renames it, and delete_doc deletes it with its script and audio."
        )
    }

    /// A linked page — a Google Doc, a Claude artifact, a Codex site — is
    /// edited where it lives, and the refusal says how the copy here follows:
    /// `link_page` again with the new text, or `unlink_page` for a Doc of
    /// ForeverLM's own. The product owner (2026-09-08) wants Docs and Sites both
    /// editable from Codex and Claude; for a site that means the route, not
    /// a copy that diverges from the page.
    private func refuseLinkedPageEdit(_ artifactID: String) async throws {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("doc_id is required.") }
        guard let artifact = try await notebookFileStorage.loadArtifacts(notebookID: nil).first(where: { $0.id == id }),
              artifact.isLinked else { return }
        let label = artifact.linkedKind?.label ?? "linked page"
        let owner = artifact.linkedKind?.productName ?? "the product that owns it"
        throw MCPError.invalidInput(
            "‘\(artifact.title)’ is a \(label): its text here is a read-only copy of the page at \(artifact.linkedURL ?? ""). Edit the page in \(owner), then call link_page with the same url and the new text to refresh the copy at once (ForeverLM also refreshes it when the doc is opened). To make it ForeverLM's own, call adopt_page — it unlinks it into a Doc and publishes it on foreverlm.com in one step, taking the page's real Markdown if you have it — or unlink_page for a Doc without a page; the \(label) itself is not touched either way."
        )
    }

    /// One targeted change to a Doc's Markdown: the exact text to find and what
    /// to put in its place. `find` must occur exactly once unless `replaceAll`.
    struct ArtifactEdit: Equatable {
        var find: String
        var replace: String
        var replaceAll: Bool = false
    }

    enum ArtifactEditError: LocalizedError, Equatable {
        case noEdits
        case emptyFind(index: Int)
        case notFound(index: Int, find: String)
        case ambiguous(index: Int, find: String, count: Int)

        var errorDescription: String? {
            switch self {
            case .noEdits:
                return "edits must hold at least one {find, replace} entry, or pass append."
            case .emptyFind(let index):
                return "edits[\(index)].find is empty. Give the exact existing text to replace; use append to add to the end."
            case .notFound(let index, let find):
                return "edits[\(index)] found no match for \(Self.excerpt(find)). Nothing was changed. Quote the text exactly as read_doc returned it, including whitespace and Markdown markers, or read_doc the region again."
            case .ambiguous(let index, let find, let count):
                return "edits[\(index)] matches \(count) places for \(Self.excerpt(find)). Nothing was changed. Include more surrounding text so it matches once, or pass replace_all: true to change every occurrence."
            }
        }

        /// The find text is not in the Doc once — the refusal a Doc that
        /// changed after it was read can explain.
        var isMatchFailure: Bool {
            switch self {
            case .notFound, .ambiguous: return true
            case .noEdits, .emptyFind: return false
            }
        }

        private static func excerpt(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: "⏎")
            let head = flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
            return "“\(head)”"
        }
    }

    /// Applies `edits` in order to `markdown`, each on the result of the last,
    /// then `append`. All-or-nothing: the first edit that does not match exactly
    /// once (or at all, with `replaceAll`) throws and nothing is returned.
    static func applyArtifactEdits(
        to markdown: String,
        edits: [ArtifactEdit],
        append: String?
    ) throws -> (markdown: String, replacements: Int) {
        guard !edits.isEmpty || append != nil else { throw ArtifactEditError.noEdits }
        var text = markdown
        var replacements = 0
        for (index, edit) in edits.enumerated() {
            guard !edit.find.isEmpty else { throw ArtifactEditError.emptyFind(index: index) }
            let count = text.components(separatedBy: edit.find).count - 1
            guard count > 0 else { throw ArtifactEditError.notFound(index: index, find: edit.find) }
            guard count == 1 || edit.replaceAll else {
                throw ArtifactEditError.ambiguous(index: index, find: edit.find, count: count)
            }
            if edit.replaceAll {
                text = text.replacingOccurrences(of: edit.find, with: edit.replace)
                replacements += count
            } else if let range = text.range(of: edit.find) {
                text.replaceSubrange(range, with: edit.replace)
                replacements += 1
            }
        }
        if let append, !append.isEmpty {
            // A blank line, so an appended heading or list starts its own block.
            if !text.isEmpty, !text.hasSuffix("\n\n") {
                text += text.hasSuffix("\n") ? "\n" : "\n\n"
            }
            text += append
        }
        return (text, replacements)
    }

    /// `edit_doc`: change a Doc without re-emitting it. A 237,000-character
    /// report cannot be carried through a tool call (2026-09-07: a chat asked to
    /// fold new material into two long reports created a third Doc instead, then
    /// refused to "risk truncating" them), so the edit names the passages to
    /// change and the body stays where it is.
    func editArtifact(
        artifactID: String,
        edits: [ArtifactEdit],
        append: String?,
        expectedRevision: String,
        publish: Bool = false
    ) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("doc_id is required.") }
        try await refuseLinkedPageEdit(id)
        let current = try await notebookFileStorage.artifactMarkdown(id)
        try Self.refuseAudioOverviewChange(current, doing: "edit_doc")
        try Self.refuseMnemonicReadingChange(current, doing: "edit_doc")
        // The learner may be typing in the Doc while an assistant edits it, and
        // the editor saves as they type, so the revision the assistant read has
        // often moved on by the time its edit arrives. Refusing on the revision
        // alone failed every edit of a Doc being written beside its chat, the
        // retry after a fresh read_doc too (product owner, 2026-09-29, rewriting a
        // Doc section by section while drafting the next paragraph himself:
        // "handle this error pls"). Every edit names the exact text it
        // replaces, and that text is checked against the Doc as it is now, so
        // the edits go onto the newer text whenever each find still matches
        // exactly once. Only an edit whose own passage changed is refused.
        let changedMeanwhile = current.revision.caseInsensitiveCompare(expectedRevision) != .orderedSame
        let edited: (markdown: String, replacements: Int)
        do {
            edited = try Self.applyArtifactEdits(to: current.markdown, edits: edits, append: append)
        } catch let error as ArtifactEditError {
            guard changedMeanwhile, error.isMatchFailure else {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            throw MCPError.invalidInput(
                "‘\(current.artifact.title)’ changed after you read it — the learner may be editing it right now — so the edits were tried against its newer text. \(error.localizedDescription) Call read_doc for the current text and its revision, and quote find text from that."
            )
        }
        let rendering = try await renderedDocPictures(in: edited.markdown, alreadyIn: current.markdown)
        let body = try await notebookFileStorage.keepDocPictures(rendering.pictures, in: edited.markdown, artifactID: id)
        let saved = try await saveEditedArtifact(id, madeFrom: current, markdown: body.markdown)
        let snapshot = saved.snapshot
        var payload: [String: Any] = [
            "doc": artifactPayload(snapshot.artifact),
            "revision": snapshot.revision,
            "replacements": edited.replacements,
            "appended": (append?.isEmpty == false),
            "total_characters": snapshot.markdown.count,
            "message": "Edited Doc ‘\(snapshot.artifact.title)’ in place for every linked Notebook.",
        ]
        if changedMeanwhile || saved.mergedIntoNewer {
            payload["doc_changed_meanwhile"] = true
            payload["doc_changed_guidance"] = "Someone — most likely the learner, typing in the Doc — changed it after you read it. Your edits were applied to the newer text and kept what they changed; the revision above is the one to pass next. Call read_doc before editing passages they may have touched, or to see what they wrote."
        }
        Self.notePictures(&payload, kept: body.kept, notShown: rendering.failures)
        await finishPublishedPage(&payload, snapshot: snapshot, republish: publish)
        return try jsonString(payload)
    }

    /// Saves an `edit_doc` result, `markdown`, over `base`, the body it was
    /// made from. The editor can save the learner's typing in the moments
    /// between the read and the write — rendering a picture takes seconds —
    /// and a write that loses that race folds the edit into the newer body
    /// line by line, as the editor folds a write that lands under its own
    /// typing (`ArtifactThreeWayMerge`). Only the same lines changed on both
    /// sides refuse it. The pictures `markdown` keeps are already the Doc's
    /// attachments, so a retry never stores them twice.
    private func saveEditedArtifact(
        _ id: String,
        madeFrom base: ArtifactMarkdownSnapshot,
        markdown: String
    ) async throws -> (snapshot: ArtifactMarkdownSnapshot, mergedIntoNewer: Bool) {
        var base = base
        var markdown = markdown
        var merged = false
        for _ in 0..<3 {
            do {
                let snapshot = try await notebookFileStorage.writeArtifactMarkdownAndSync(
                    artifactID: id,
                    markdown: markdown,
                    expectedRevision: base.revision,
                    versionReason: .assistantEdit
                )
                return (snapshot, merged)
            } catch ArtifactError.conflict {
                let latest = try await notebookFileStorage.artifactMarkdown(id)
                guard case .merged(let combined) = ArtifactThreeWayMerge.merge(
                    base: base.markdown,
                    mine: markdown,
                    theirs: latest.markdown
                ) else { break }
                base = latest
                markdown = combined
                merged = true
            }
        }
        throw MCPError.invalidInput(
            "Nothing was changed. ‘\(base.artifact.title)’ is being edited right now, and the passages these edits touch changed while they were being saved. Call read_doc for the current text and its revision, and quote find text from that."
        )
    }

    /// A Doc's foreverlm.com page is rendered when publish_doc runs, not when the
    /// body changes — the app's Publish sheet works the same way. A write result
    /// therefore says so, or a chat asked to "fix the published page" edits the
    /// Doc and leaves the page as it was. With `republish` (the `publish`
    /// argument of write_doc, edit_doc and restore_doc_version) a Doc that has
    /// a page gets the page updated in the same call, at the same address with
    /// the same readers, so a Site on foreverlm.com is edited from Codex or
    /// Claude in one step. A Doc with no page is never published by it: that is
    /// publish_doc's deliberate act.
    func finishPublishedPage(
        _ payload: inout [String: Any],
        snapshot: ArtifactMarkdownSnapshot,
        republish: Bool
    ) async {
        // Publication is server state: a signed-out or offline Mac answers
        // nothing, and the write result must not fail or wait long for it.
        guard ManagedAI.isSignedIn,
              let status = try? await DocPublishing.status(docID: snapshot.artifact.id) else {
            if republish {
                payload["page_updated"] = false
                payload["guidance"] = "This Doc has no published page (or its publication state is not available right now), so publish was ignored. Call publish_doc to publish it."
            }
            return
        }
        payload["published"] = true
        payload["published_url"] = status.url.absoluteString
        guard republish else {
            payload["page_stale"] = true
            payload["guidance"] = "This Doc is published at published_url. The page still shows the previous body; call publish_doc with this doc_id, or pass publish: true to this call, to update it."
            return
        }
        do {
            // The page reads block references and title links as words
            // (docs/notes-graph-design.md, "Invariants").
            let updated = try await DocPublishing.publish(
                docID: snapshot.artifact.id,
                title: snapshot.artifact.title,
                markdown: try await notebookFileStorage.docGraphResolvedMarkdown(snapshot.markdown, teamID: snapshot.artifact.teamID),
                access: .keep,
                slug: nil
            )
            payload["page_updated"] = true
            payload["page_stale"] = false
            payload["published_url"] = updated.url.absoluteString
            payload["guidance"] = "The page at published_url now shows this body."
        } catch {
            payload["page_updated"] = false
            payload["page_stale"] = true
            payload["guidance"] = "The Doc was saved but its page could not be updated: \(error.localizedDescription). Call publish_doc with this doc_id to retry."
        }
    }

    func updateArtifact(
        artifactID: String,
        title: String?,
        homeNotebookID: String?,
        notebookIDs: [String]?,
        isDraft: Bool? = nil,
        isArchived: Bool? = nil,
        isHidden: Bool? = nil
    ) async throws -> String {
        // Hiding is the learner's view of the record and moves nothing on it, so
        // a call that only hides or shows never runs the record update — whose
        // `updatedAt` bump would republish the Doc to every device and team.
        let touchesRecord = title != nil || homeNotebookID != nil || notebookIDs != nil
            || isDraft != nil || isArchived != nil
        var artifact: ArtifactRecord
        if touchesRecord || isHidden == nil {
            artifact = try await notebookFileStorage.updateArtifact(
                artifactID: artifactID,
                title: title,
                homeNotebookID: homeNotebookID,
                linkedNotebookIDs: notebookIDs,
                isDraft: isDraft,
                isArchived: isArchived
            )
        } else {
            guard let current = try await notebookFileStorage.loadArtifacts(notebookID: nil)
                .first(where: { $0.id == artifactID }) else {
                throw ArtifactError.unavailable(artifactID)
            }
            artifact = current
        }
        if let isHidden {
            artifact = try await notebookFileStorage.setArtifactHidden(artifactID: artifactID, isHidden: isHidden)
        }
        return try jsonString([
            "doc": artifactPayload(artifact),
            "message": "Updated the Doc without copying the document.",
        ] as [String: Any])
    }

    /// The Docs pane's Move to Trash, and Remove from Docs / Sites for a linked page —
    /// without the confirmation sheet, which is why the tool description asks
    /// the caller to confirm the title first.
    ///
    /// An audio overview goes the way its row's Delete takes it
    /// (`AudioOverviewCleanup.deleteOverview`): its narration stopped, its
    /// generation cancelled, its record and script source deleted, and its
    /// audio files removed. `removeAudioFiles` is that last step, which a
    /// test hands in.
    func deleteArtifact(
        artifactID: String,
        removeAudioFiles: @escaping @Sendable (String) async -> Void = { await AudioOverviewCleanup.removeAudioFiles(ofCarrier: $0) }
    ) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("doc_id is required.") }
        guard let artifact = try await notebookFileStorage.loadArtifacts(notebookID: nil).first(where: { $0.id == id }) else {
            throw MCPError.notFound("Doc not found: \(id). Call list_docs for the current doc ids.")
        }
        let isOverview = try knowledgeStore().isAudioOverview(artifact)
        if isOverview {
            try await AudioOverviewCleanup.deleteOverview(id, storage: notebookFileStorage, removeAudioFiles: removeAudioFiles)
        } else {
            try await notebookFileStorage.deleteArtifact(id)
        }
        let message: String
        if artifact.isLinked {
            message = "Removed ‘\(artifact.title)’ from Docs. The \(artifact.linkedKind?.label ?? "page") itself was not touched."
        } else if isOverview {
            message = "Deleted the audio overview ‘\(artifact.title)’ and its script source on every device."
        } else {
            message = "Moved Doc ‘\(artifact.title)’ to the Trash."
        }
        return try jsonString([
            "status": artifact.isLinked ? "removed" : "deleted",
            "doc": artifactPayload(artifact, isAudioOverview: isOverview),
            "message": message,
        ] as [String: Any])
    }

    /// Put a page — a Google Doc, a Claude artifact or a Codex site — in the
    /// library from its link: a Google Doc in Docs, the other two in Sites. The title and the text copy are fetched by the app, which
    /// holds the sign-ins and renders the page — the tool has neither — so a
    /// doc linked here reads as its placeholder until ForeverLM opens it, the
    /// same as a link pasted while offline. A caller that can read the page
    /// itself (Claude Code reads its own artifacts) may pass `text` as the
    /// copy to hold until then.
    func linkPageArtifact(
        urlString: String,
        title: String?,
        text: String? = nil,
        homeNotebookID: String?,
        notebookIDs: [String]
    ) async throws -> String {
        let url: URL
        do {
            url = try LinkedPage.canonicalURL(from: urlString)
        } catch {
            throw MCPError.invalidInput(
                "url must be a Google Docs document link (docs.google.com/document/d/…), a Claude artifact link (claude.ai/code/artifact/…) or a Codex site (….chatgpt.site). \(error.localizedDescription)"
            )
        }
        let kind = LinkedPage.kind(of: url) ?? .googleDoc
        if var existing = try await notebookFileStorage.loadArtifacts(notebookID: nil)
            .first(where: { $0.linkedURL == url.absoluteString }) {
            // The way a caller that can read the page hands over a newer copy:
            // Claude after editing its own artifact, Codex after changing a
            // public site. The record, its title and its Notebooks stay.
            let refreshed = LinkedPage.normalizedText(text ?? "")
            if !refreshed.isEmpty {
                existing = try await notebookFileStorage.replaceLinkedArtifactExport(
                    artifactID: existing.id, text: refreshed
                ).artifact
            }
            return try jsonString([
                "status": "already_linked",
                "doc": artifactPayload(existing),
                "text_copy_refreshed": !refreshed.isEmpty,
                "message": refreshed.isEmpty
                    ? "‘\(existing.title)’ is already linked to that \(kind.label). Pass text to refresh ForeverLM's copy of it."
                    : "‘\(existing.title)’ is already linked to that \(kind.label); its text copy was replaced with the text passed.",
            ] as [String: Any])
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var artifact = try await notebookFileStorage.createLinkedArtifact(
            url: url,
            title: trimmedTitle.isEmpty ? kind.placeholderTitle : trimmedTitle,
            homeNotebookID: homeNotebookID,
            linkedNotebookIDs: notebookIDs
        )
        let initialText = LinkedPage.normalizedText(text ?? "")
        if !initialText.isEmpty {
            artifact = try await notebookFileStorage.replaceLinkedArtifactExport(
                artifactID: artifact.id, text: initialText
            ).artifact
        }
        let follows = kind.textCopySource == .export
            ? "ForeverLM fetches its title and text export when the doc is next opened in the app"
            : "ForeverLM takes its title and text copy from the page when the doc is next opened in the app"
        let place = "It is in the app's \(kind.section.title) section."
        return try jsonString([
            "status": "linked",
            "doc": artifactPayload(artifact),
            "message": initialText.isEmpty
                ? "Linked the \(kind.label) as ‘\(artifact.title)’. \(place) \(follows); until then read_doc returns an empty body."
                : "Linked the \(kind.label) as ‘\(artifact.title)’ with the text passed as its copy. \(place) \(follows).",
        ] as [String: Any])
    }

    /// `link_google_doc`, kept for callers that learned the tool before
    /// link_page existed: the same call.
    func linkGoogleDocArtifact(
        urlString: String,
        title: String?,
        homeNotebookID: String?,
        notebookIDs: [String]
    ) async throws -> String {
        try await linkPageArtifact(
            urlString: urlString, title: title, text: nil,
            homeNotebookID: homeNotebookID, notebookIDs: notebookIDs
        )
    }

    /// Publish the stored body as a page on foreverlm.com, or update the page
    /// the doc already has. The same call the pane's Publish makes: the site
    /// renders the Markdown, the managed session names the owner, and the
    /// address is stable across updates. Spec: docs/docs-design.md → Publishing.
    /// The access and address a publish asks for, validated the same way for
    /// `publish_doc` and `adopt_page`.
    static func publishOptions(readers: [String]?, slug: String?) throws -> (access: DocPageAccess, slug: String?) {
        var customSlug: String?
        if let slug, !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = DocPublishing.normalizeCustomSlug(slug) else {
                throw MCPError.invalidInput("slug must be 3 to 64 lowercase letters, digits and single hyphens, starting and ending with a letter or digit, for example obesity-landscape-2026.")
            }
            customSlug = normalized
        }
        let accessChange: DocPageAccess
        switch readers {
        case nil: accessChange = .keep
        case let list?:
            var normalized: [String] = []
            for reader in list {
                guard let address = DocPublishing.normalizeReader(reader) else {
                    throw MCPError.invalidInput("readers must be email addresses; “\(reader)” is not one. Pass an empty list to open the page to anyone with the link.")
                }
                if !normalized.contains(address) { normalized.append(address) }
            }
            guard normalized.count <= DocPublishing.maxReaders else {
                throw MCPError.invalidInput("A page is shared with at most \(DocPublishing.maxReaders) readers.")
            }
            accessChange = normalized.isEmpty ? .open : .readers(normalized)
        }
        return (accessChange, customSlug)
    }

    func publishArtifact(artifactID: String, readers: [String]?, slug: String? = nil) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("doc_id is required.") }
        let (accessChange, customSlug) = try Self.publishOptions(readers: readers, slug: slug)
        let snapshot = try await notebookFileStorage.artifactMarkdown(id)
        guard !snapshot.artifact.isLinked else {
            throw MCPError.invalidInput("‘\(snapshot.artifact.title)’ is a linked \(snapshot.artifact.linkedKind?.label ?? "page"); share the page itself. Only Markdown Docs are published.")
        }
        try Self.refuseAudioOverviewChange(snapshot, doing: "publish_doc")
        try Self.refuseMnemonicReadingChange(snapshot, doing: "publish_doc")
        // A reader outside the app gets the words, never `((id))` or ` ^id`
        // (docs/notes-graph-design.md, "Invariants").
        let status = try await DocPublishing.publish(
            docID: id,
            title: snapshot.artifact.title,
            markdown: try await notebookFileStorage.docGraphResolvedMarkdown(snapshot.markdown, teamID: snapshot.artifact.teamID),
            access: accessChange,
            slug: customSlug
        )
        var payload: [String: Any] = [
            "status": "published",
            "url": status.url.absoluteString,
            "slug": status.slug,
            "custom_address": status.isCustomSlug,
            "restricted": status.isProtected,
            "readers": status.readers,
            "published_at": KnowledgeStore.iso8601Formatter.string(from: status.publishedAt),
            "updated_at": KnowledgeStore.iso8601Formatter.string(from: status.updatedAt),
            "doc": artifactPayload(snapshot.artifact),
            "message": status.isProtected
                ? (status.readers.isEmpty
                    ? "‘\(snapshot.artifact.title)’ is published at \(status.url.absoluteString), still guarded by the password it had; pass readers to share it by email instead. publish_doc again after edits to update the page at the same address."
                    : "‘\(snapshot.artifact.title)’ is published at \(status.url.absoluteString) and shared with \(status.readers.joined(separator: ", ")). Each of them enters their address on the page and follows the emailed link; publish_doc again after edits to update the page at the same address.")
                : "‘\(snapshot.artifact.title)’ is published at \(status.url.absoluteString). Anyone with the link can read it; publish_doc again after edits to update the page at the same address.",
        ]
        if let password = status.password { payload["password"] = password }
        return try jsonString(payload)
    }

    /// Take the page down; the doc is untouched.
    func unpublishArtifact(artifactID: String) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("doc_id is required.") }
        let snapshot = try await notebookFileStorage.artifactMarkdown(id)
        try await DocPublishing.unpublish(docID: id)
        return try jsonString([
            "status": "unpublished",
            "doc": artifactPayload(snapshot.artifact),
            "message": "‘\(snapshot.artifact.title)’ is no longer published; its foreverlm.com link stops working within a few minutes.",
        ] as [String: Any])
    }

    /// The inverse of linking: the stored export becomes the editable body.
    func unlinkPageArtifact(artifactID: String) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("doc_id is required.") }
        let kind = try await notebookFileStorage.loadArtifacts(notebookID: nil)
            .first(where: { $0.id == id })?.linkedKind
        let artifact = try await notebookFileStorage.unlinkArtifact(artifactID: id)
        let snapshot = try await notebookFileStorage.artifactMarkdown(id)
        return try jsonString([
            "status": "unlinked",
            "doc": artifactPayload(artifact),
            "revision": snapshot.revision,
            "message": "‘\(artifact.title)’ is a Markdown Doc again, with ForeverLM's text copy as its body. Pass revision to write_doc to edit it. The \(kind?.label ?? "page") itself was not touched.",
        ] as [String: Any])
    }

    /// `unlink_google_doc`, kept for older callers: the same call.
    func unlinkGoogleDocArtifact(artifactID: String) async throws -> String {
        try await unlinkPageArtifact(artifactID: artifactID)
    }

    /// `adopt_page`: a linked page becomes ForeverLM's own published page in
    /// one call — unlinked into a Markdown Doc, given the caller's Markdown when
    /// it has the real content (Codex built the site; it knows what is on it),
    /// and published on foreverlm.com, where write_doc and edit_doc with
    /// publish edit it from then on. The product owner (2026-09-08), shown that a Codex
    /// site can only be changed in Codex: "so can you make it a foreverlm site;
    /// and then expose mcp tools so that i can edit it in codex?"
    ///
    /// The sign-in is checked before anything changes, so a signed-out Mac
    /// refuses with the Doc still linked. A publish that fails after the unlink
    /// leaves an ordinary Doc, and the error says so and how to finish.
    /// `publish` is injectable so the tests never reach foreverlm.com.
    func adoptPageArtifact(
        artifactID: String,
        markdown: String?,
        readers: [String]?,
        slug: String?,
        isSignedIn: Bool = ManagedAI.isSignedIn,
        publish: @Sendable (String, String, String, DocPageAccess, String?) async throws -> PublishedDocStatus = {
            try await DocPublishing.publish(docID: $0, title: $1, markdown: $2, access: $3, slug: $4)
        }
    ) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("doc_id is required.") }
        let (access, customSlug) = try Self.publishOptions(readers: readers, slug: slug)
        let linked = try await notebookFileStorage.artifactMarkdown(id)
        guard linked.artifact.isLinked, let kind = linked.artifact.linkedKind else {
            throw MCPError.invalidInput("‘\(linked.artifact.title)’ is already a ForeverLM Doc. publish_doc publishes it, and write_doc or edit_doc with publish edit its page.")
        }
        guard isSignedIn else {
            throw MCPError.invalidInput("\(DocPublishingError.signedOut.localizedDescription) Nothing was changed: ‘\(linked.artifact.title)’ is still a linked \(kind.label).")
        }
        let sourceURL = linked.artifact.linkedURL ?? ""
        let rendering = try await renderedDocPictures(in: markdown ?? "", alreadyIn: linked.markdown)
        _ = try await notebookFileStorage.unlinkArtifact(artifactID: id)
        var snapshot = try await notebookFileStorage.artifactMarkdown(id)
        let body: String
        if let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kept = try await notebookFileStorage.keepDocPictures(rendering.pictures, in: markdown, artifactID: id)
            snapshot = try await notebookFileStorage.writeArtifactMarkdownAndSync(
                artifactID: id,
                markdown: kept.markdown,
                expectedRevision: snapshot.revision,
                versionReason: .assistantEdit
            )
            body = "markdown"
        } else {
            body = "text_copy"
        }
        let status: PublishedDocStatus
        do {
            let page = try await notebookFileStorage.docGraphResolvedMarkdown(snapshot.markdown, teamID: snapshot.artifact.teamID)
            status = try await publish(id, snapshot.artifact.title, page, access, customSlug)
        } catch {
            throw MCPError.invalidInput("‘\(snapshot.artifact.title)’ is a Markdown Doc now (revision \(snapshot.revision)), no longer linked to \(sourceURL), but its page was not published: \(error.localizedDescription) Call publish_doc to publish it.")
        }
        let rendered = body == "markdown" ? "the Markdown passed" : "ForeverLM's text copy of the \(kind.label)"
        return try jsonString([
            "status": "adopted",
            "doc": artifactPayload(snapshot.artifact),
            "revision": snapshot.revision,
            "body": body,
            "source_url": sourceURL,
            "source_kind": kind.rawValue,
            "url": status.url.absoluteString,
            "slug": status.slug,
            "restricted": status.isProtected,
            "readers": status.readers,
            "message": "‘\(snapshot.artifact.title)’ is a ForeverLM page now at \(status.url.absoluteString), rendered from \(rendered). Edit it with edit_doc or write_doc, passing revision as expected_revision and publish true to update the page in the same call. The \(kind.label) at \(sourceURL) itself was not touched.",
        ] as [String: Any])
    }

    // MARK: - Passages a chat was opened on

    /// Every conversation this doc's passages started. The quote is the point:
    /// it says which sentence was being asked about, and stays readable after
    /// the doc has been rewritten around it.
    func listArtifactChats(artifactID: String) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw MCPError.invalidInput("doc_id is required.")
        }
        // Reading the doc first turns an unknown id into the same clear error
        // every other artifact tool gives, instead of an empty, plausible list.
        let snapshot = try await notebookFileStorage.artifactMarkdown(id)
        let links = try await notebookFileStorage.artifactChatLinks(id)
        let sessions = try await notebookFileStorage.loadReviewSessionLinks()
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let formatter = KnowledgeStore.iso8601Formatter
        return try jsonString([
            "doc_id": id,
            "doc_title": snapshot.artifact.title,
            "revision": snapshot.revision,
            "chat_count": links.count,
            "chats": links.map { link -> [String: Any] in
                [
                    "link_id": link.id,
                    "session_id": link.sessionID,
                    "session_title": sessionsByID[link.sessionID]?.title.map { $0 as Any } ?? NSNull(),
                    "quote": link.anchorQuote,
                    "section_title": link.sectionTitle,
                    "anchor_revision": link.anchorRevision,
                    "anchor_start": link.anchorStart,
                    "anchor_end": link.anchorEnd,
                    // The offsets describe the revision they were taken in.
                    // False means the doc has moved on and only the quote can
                    // still be trusted to find the passage.
                    "anchor_is_current": link.locatesPassage(inRevision: snapshot.revision),
                    "created_at": formatter.string(from: link.createdAt),
                ]
            },
            "guidance": "Resume a conversation with its session_id. When anchor_is_current is false the doc changed after the chat, so locate the passage by searching for quote rather than by anchor_start.",
        ] as [String: Any])
    }

    /// Records that a conversation is about a passage of a doc — the same thing
    /// highlighting a passage and hitting Chat writes down, for a chat that
    /// arrived at the doc some other way.
    func linkArtifactPassageToChat(
        artifactID: String,
        sessionID: String,
        quote: String,
        sectionTitle: String
    ) async throws -> String {
        let id = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let passage = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !session.isEmpty, !passage.isEmpty else {
            throw MCPError.invalidInput("doc_id, session_id and quote are all required.")
        }
        let snapshot = try await notebookFileStorage.artifactMarkdown(id)
        let sessions = try await notebookFileStorage.loadReviewSessionLinks()
        guard sessions.contains(where: { $0.id == session }) else {
            throw MCPError.invalidInput("No chat session with ID \(session).")
        }
        // Locate the quote in the doc as it stands, so the link gets real
        // offsets when the words are actually there. A quote that is not in the
        // doc still links — a chat may be about a passage that has since been
        // rewritten — but it links with no position, which `anchor_is_current`
        // then reports honestly.
        var start = 0
        var end = 0
        var anchorRevision = ""
        if let range = snapshot.markdown.range(of: passage) {
            start = snapshot.markdown.distance(from: snapshot.markdown.startIndex, to: range.lowerBound)
            end = snapshot.markdown.distance(from: snapshot.markdown.startIndex, to: range.upperBound)
            anchorRevision = snapshot.revision
        }
        guard let link = try await notebookFileStorage.linkArtifactPassageToChat(
            artifactID: id,
            sessionID: session,
            selectionStart: start,
            selectionEnd: end,
            quote: passage,
            sectionTitle: sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            anchorRevision: anchorRevision
        ) else {
            throw MCPError.invalidInput("The passage must contain some text.")
        }
        return try jsonString([
            "link_id": link.id,
            "doc_id": link.artifactID,
            "session_id": link.sessionID,
            "quote": link.anchorQuote,
            "anchor_is_current": link.locatesPassage(inRevision: snapshot.revision),
            "message": "Linked this chat to a passage of ‘\(snapshot.artifact.title)’.",
        ] as [String: Any])
    }

    /// Forgets one passage-to-chat link. Neither the doc nor the conversation is
    /// touched — only the claim that the two are related.
    func unlinkArtifactChat(linkID: String) async throws -> String {
        let id = linkID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw MCPError.invalidInput("link_id is required.")
        }
        try await notebookFileStorage.deleteArtifactChatLink(id)
        return try jsonString([
            "link_id": id,
            "message": "Forgot the link between that chat and the passage. The chat and the doc are both unchanged.",
        ] as [String: Any])
    }

    // MARK: list_source_artifacts

    /// The artifacts a source is linked to, the way the app's **Linked in**
    /// menu lists them (`StorageService.artifactsLinked(toSource:)`).
    func listSourceArtifacts(sourceID rawSourceID: String) async throws -> String {
        guard let token = Self.trimmedOrNil(rawSourceID) else {
            throw MCPError.invalidInput("source_id is required. Use list_sources or search_sources_semantic to find it.")
        }
        let found = try resolveAnimationSources([token])
        guard let resolved = found.resolved.first else {
            throw MCPError.invalidInput("No library source answers to \(token). Pass a source id from list_sources or search_sources_semantic, a foreverlm://source/<id> link, or a web address the library holds.")
        }
        let links = try await notebookFileStorage.artifactsLinked(toSource: resolved)
        let entries: [[String: Any]] = links.map { link in
            var entry = artifactPayload(link.artifact)
            entry["artifact_id"] = link.artifact.id
            entry["linked_by"] = link.ways.sorted().map(\.rawValue)
            entry["url"] = link.artifact.linkedURL.map { $0 as Any } ?? NSNull()
            return entry
        }
        let title = try animationSourceDescriptors(for: [resolved]).first?["title"] as? String ?? resolved
        return try jsonString([
            "source_id": resolved,
            "source_title": title,
            "artifact_count": entries.count,
            "artifacts": entries,
            "generated_at": KnowledgeStore.iso8601Formatter.string(from: Date()),
            "guidance": entries.isEmpty
                ? "Nothing links to this source yet: no Doc is grounded on it or cites it, and no site or animation names it."
                : "grounded means the record's own source links name the source; cited means a Doc's body references it. read_doc reads a Doc, read_site_file a site's files; an animation plays at its url.",
        ])
    }

    /// `isAudioOverview` is the caller's answer where it has a better one
    /// than the kind — the body's marker, or the script source an older
    /// build's kindless record still has; nil reads the kind.
    func artifactPayload(_ artifact: ArtifactRecord, isAudioOverview: Bool? = nil) -> [String: Any] {
        var payload = Self.artifactFields(artifact)
        // An audio overview's script and audio live on its carrier source:
        // get_source_content reads the script, get_source_audio_status
        // follows the audio, and delete_doc removes both.
        if isAudioOverview ?? artifact.isAudioOverview {
            payload["kind"] = ArtifactKind.audioOverview.rawValue
            payload["audio_source_id"] = GeneratedAudioOverview.carrierSourceID(artifactID: artifact.id)
        }
        return payload
    }

    private static func artifactFields(_ artifact: ArtifactRecord) -> [String: Any] {
        [
            "id": artifact.id,
            "title": artifact.title,
            // The record's own kind outranks its link: an animation is hosted
            // as a ForeverLM site and would otherwise read as one.
            "kind": artifact.kind?.rawValue ?? (artifact.isLinked ? (artifact.linkedKind?.rawValue ?? "linked") : "markdown"),
            "section": artifact.section.rawValue,
            "source_ids": artifact.sourceIDs,
            "linked_url": artifact.linkedURL.map { $0 as Any } ?? NSNull(),
            "read_only": artifact.isLinked,
            // The library the record is in: null for My Library, else the
            // team's id — how a list_docs reader tells a team copy from the
            // original, which the app tells apart by the open library.
            "team_id": artifact.teamID.map { $0 as Any } ?? NSNull(),
            "is_draft": artifact.isDraft,
            "is_archived": artifact.isArchived,
            "archived_at": artifact.archivedAt.map { KnowledgeStore.iso8601Formatter.string(from: $0) as Any } ?? NSNull(),
            "is_hidden": artifact.isHidden,
            "hidden_at": artifact.hiddenAt.map { KnowledgeStore.iso8601Formatter.string(from: $0) as Any } ?? NSNull(),
            "home_notebook_id": artifact.homeNotebookID.map { $0 as Any } ?? NSNull(),
            "notebook_ids": artifact.linkedNotebookIDs,
            "created_at": KnowledgeStore.iso8601Formatter.string(from: artifact.createdAt),
            "updated_at": KnowledgeStore.iso8601Formatter.string(from: artifact.updatedAt),
        ]
    }
}
