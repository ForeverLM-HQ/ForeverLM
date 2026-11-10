import Foundation

// MARK: - Teams and Notebook tasks (MCP tools)
//
// A team is a second library several people share: a CloudKit zone in the
// owner's iCloud, projected into this Mac's SQLite. Sharing copies an item into
// the team's namespace and leaves the original alone; a chat shares as a
// read-only transcript. Every Notebook can carry tasks, and a team Notebook's
// tasks are the team's, assignable to a member by CloudKit user record name.
// See docs/teams-design.md.
//
// Everything here goes through StorageService so files and rows move
// together. These tools are desktop-only in the public
// allowlist: the hosted account has no team zone to stand in for the Mac.

extension MCPDataStore {

    // MARK: Teams

    func listTeams() async throws -> String {
        let teams = try await notebookFileStorage.loadTeams()
        var payloads: [[String: Any]] = []
        for team in teams {
            let members = try await notebookFileStorage.loadTeamMembers(teamID: team.id)
            payloads.append(teamPayload(team, members: members))
        }
        return try jsonString([
            "count": teams.count,
            "teams": payloads,
            "guidance": teams.isEmpty
                ? "No teams on this Mac. create_team makes one this account owns; an invitation someone else sent is accepted in ForeverLM, not here."
                : "A team is a library of its own. share_with_team copies sources, Notebooks, Docs, chats or courses into it and never moves the originals. A member's user_record_name is what a task's assignee_record_name carries; is_current_user marks this account. permission readOnly means share_with_team and the task tools will refuse writes into that team.",
        ] as [String: Any])
    }

    func createTeam(name: String?) async throws -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidInput("A team needs a name.")
        }
        let team: TeamRecord
        do {
            team = try await notebookFileStorage.createTeam(name: trimmed)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let members = try await notebookFileStorage.loadTeamMembers(teamID: team.id)
        return try jsonString([
            "team": teamPayload(team, members: members),
            "message": "Created team ‘\(team.name)’. This account owns it; its content lives in this account's iCloud.",
            "guidance": "Members are invited from ForeverLM (Settings › Data & Privacy › Teams) through Apple's sharing sheet; there is no MCP invitation. Use share_with_team to put sources, Notebooks, Docs, chats or courses into the team.",
        ] as [String: Any])
    }

    // MARK: Sharing

    enum TeamShareKind: String, CaseIterable {
        case source, notebook, doc, chat, course
    }

    /// Additions to a Notebook a team holds follow it (docs/teams-design.md,
    /// decision 10). Tools that file something under a Notebook through this
    /// store's own SQLite connection hand the follow-on to StorageService,
    /// which owns the files a team copy needs; the tool's reply does not wait
    /// for the team copies.
    func followTeamShares(_ work: @escaping @Sendable (StorageService) async -> Void) {
        let storage = notebookFileStorage
        Task(priority: .utility) { await work(storage) }
    }

    /// `rightsAnswer` is the call's `rights_affirmed_by_learner`, which the
    /// registry's dispatch always passes; a caller that is not an assistant's
    /// call (the copy's own tests) passes nil and is not asked.
    func shareWithTeam(
        teamID: String?,
        kind rawKind: String?,
        ids rawIDs: [String],
        includeSources: Bool?,
        includeDocs: Bool?,
        includeChats: Bool? = nil,
        includeCitedSources: Bool? = nil,
        rightsAnswer: SharingRightsAnswer? = nil
    ) async throws -> String {
        let team = try await requireEditableTeam(teamID, action: "share into it")
        let kindText = (rawKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = TeamShareKind(rawValue: kindText) else {
            throw MCPError.invalidInput(
                "kind must be one of: \(TeamShareKind.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        let ids = dictUnique(rawIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else {
            throw MCPError.invalidInput("ids must name at least one \(kind.rawValue) to share.")
        }
        if kind != .notebook, includeSources != nil || includeDocs != nil || includeChats != nil {
            throw MCPError.invalidInput("include_sources, include_docs and include_chats only apply when kind is notebook.")
        }
        if kind != .doc, includeCitedSources != nil {
            throw MCPError.invalidInput("include_cited_sources only applies when kind is doc.")
        }

        let store = try knowledgeStore()
        try validateShareIDs(ids, kind: kind, store: store)
        // Every kind but a chat's transcript gives the team's members copies
        // of sources, so it waits on the learner's word (docs/teams-design.md,
        // decision 22); asked after the checks above, so an unknown id or a
        // read-only team is refused first.
        if let rightsAnswer, kind != .chat {
            try await requireSharingRights(rightsAnswer)
        }

        var copies: [[String: Any]] = []
        var courseSourcesShared: [[String: Any]] = []
        var linkedSourcesShared: [[String: Any]] = []
        var citedSourcesShared: [[String: Any]] = []
        var sourcesNotShared: [[String: Any]] = []
        do {
            switch kind {
            case .source:
                let copyIDs = try await notebookFileStorage.shareSources(ids, withTeam: team.id)
                for (original, copy) in zip(ids, copyIDs) {
                    copies.append(["original_id": original, "team_copy_id": copy])
                }
            case .notebook:
                for id in ids {
                    let copy = try await notebookFileStorage.shareNotebook(
                        id,
                        withTeam: team.id,
                        includeSources: includeSources ?? true,
                        includeDocs: includeDocs ?? true,
                        includeChats: includeChats ?? true
                    )
                    // Generation 2 moves a notebook into a space this account owns (D21): the move is
                    // queued for the Mac's move job, and the notebook keeps its id.
                    copies.append(copy == id ? ["original_id": id, "moving_into_space": true] : ["original_id": id, "team_copy_id": copy])
                }
            case .doc:
                for id in ids {
                    // The sources travel with the Doc by default: the ones
                    // the record carries always, since the copy names them
                    // by the team's ids; the closed sources its body cites
                    // unless the caller opted out (docs/teams-design.md,
                    // decision 16).
                    let copy = try await notebookFileStorage.shareArtifact(
                        id,
                        withTeam: team.id,
                        carryCitedSources: includeCitedSources ?? true
                    )
                    copies.append(["original_id": id, "team_copy_id": copy.id])
                    for source in copy.carriedSources.linked {
                        linkedSourcesShared.append(["doc_id": id, "original_id": source.originalID, "team_copy_id": source.teamCopyID, "title": source.title, "url": source.url])
                    }
                    for source in copy.carriedSources.cited {
                        citedSourcesShared.append(["doc_id": id, "original_id": source.originalID, "team_copy_id": source.teamCopyID, "title": source.title, "url": source.url])
                    }
                    for failure in copy.carriedSources.failed {
                        sourcesNotShared.append(["doc_id": id, "original_id": failure.originalID, "reason": failure.reason])
                    }
                }
            case .chat:
                for id in ids {
                    let teamNotebookID = try teamNotebookID(forChat: id, teamID: team.id, store: store)
                    let copy = try await notebookFileStorage.shareChat(id, withTeam: team.id, notebookID: teamNotebookID)
                    var entry: [String: Any] = ["original_id": id, "team_copy_id": copy]
                    if let teamNotebookID { entry["team_notebook_id"] = teamNotebookID }
                    copies.append(entry)
                }
            case .course:
                // Everything on the course's path travels: the lecture
                // videos, readings and material, copied into the team with
                // their files (docs/teams-design.md, decision 21).
                for id in ids {
                    let copy = try await notebookFileStorage.shareCourse(id, withTeam: team.id)
                    var entry: [String: Any] = ["original_id": id, "team_copy_id": copy.id]
                    if copy.itemsLeftOut > 0 { entry["lecture_items_left_out"] = copy.itemsLeftOut }
                    copies.append(entry)
                    for source in copy.carriedSources.linked {
                        courseSourcesShared.append(["course_id": id, "original_id": source.originalID, "team_copy_id": source.teamCopyID, "title": source.title, "url": source.url])
                    }
                    for failure in copy.carriedSources.failed {
                        sourcesNotShared.append(["course_id": id, "original_id": failure.originalID, "reason": failure.reason])
                    }
                }
            }
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }

        let noun = shareNoun(kind, count: ids.count)
        var detail: String
        switch kind {
        case .source:
            detail = "Each copy carries the team's own copy of the file; the originals stay in My Library untouched."
        case .notebook:
            detail = "The copy carries the Notebook's instructions, research questions and nested Goals" +
                ((includeSources ?? true) ? ", with its sources copied into the team" : "") +
                ((includeDocs ?? true) ? ", its Docs" : "") +
                ((includeChats ?? true) ? ", and its chats as read-only transcripts" : "") +
                ". The original Notebook and its progress stay in My Library. From now on whatever is filed under the Notebook (a source, a Goal, a Doc, a chat and its later turns) follows it into the team."
        case .doc:
            detail = "Members open the copy in their own ForeverLM through the team; no publishing and no password are involved. The original Doc stays in My Library. A page — a ForeverLM site, a Claude artifact, a Codex site — shares as the page itself, listed under the team's Sites and keyed by its address, so sharing a rebuilt site updates the one team entry; a ForeverLM site this account published is opened to the team's members."
        case .chat:
            detail = "A chat shares as a read-only transcript: questions, answers and replies, with scores, ratings and reading context stripped. The original chat stays private and live."
        case .course:
            detail = "The copy carries the course's lectures, readings, material and quizzes, with every source on its path copied into the team, files included. Each member takes it in their own ForeverLM with their own progress: lectures watched, completed quiz sittings and scores, and the gate that holds back what follows an uncompleted quiz. The original course and this account's progress stay in My Library. Sharing the course again brings the team's copy up to date; quizzes a teammate wrote on it stay."
        }
        // What travelled with the Docs: the sources they carry, the closed
        // sources they cite, and what could not be copied.
        var sourcesNote = ""
        if kind == .doc {
            let travelled = linkedSourcesShared.count + citedSourcesShared.count
            if travelled > 0 {
                sourcesNote = " \(travelled) source\(travelled == 1 ? "" : "s") the team lacked travelled with \(ids.count == 1 ? "it" : "them") (\(linkedSourcesShared.count) linked, \(citedSourcesShared.count) cited); the team's copies carry the files."
            } else {
                sourcesNote = " The team already held every source the Doc carries\(includeCitedSources == false ? "" : " or cites"), so no source needed to travel."
            }
            if includeCitedSources == false {
                sourcesNote += " Cited sources were left behind as asked (include_cited_sources: false); teammates can ask for them from the Doc's cards (request_share)."
            }
            if !sourcesNotShared.isEmpty {
                sourcesNote += " \(sourcesNotShared.count) source\(sourcesNotShared.count == 1 ? "" : "s") could not be copied; see sources_not_shared."
            }
        }
        if kind == .course {
            sourcesNote = courseSourcesShared.isEmpty
                ? " The team already held every source on the course's path."
                : " \(courseSourcesShared.count) source\(courseSourcesShared.count == 1 ? "" : "s") the team lacked travelled with \(ids.count == 1 ? "it" : "them"); see course_sources_shared."
            if !sourcesNotShared.isEmpty {
                sourcesNote += " \(sourcesNotShared.count) source\(sourcesNotShared.count == 1 ? "" : "s") could not be copied, and the lecture items that needed them were left out; see sources_not_shared."
            }
        }
        // Generation 2's team is a space: one notebook is edited in place, so nothing follows a copy,
        // and a notebook shared into a space this account owns moves there (§9.4, D21).
        detail += kind == .notebook && team.role == .owner
            ? " This team is a space you own, so the notebook moves into it once your Mac runs the move; it keeps its id and everything in it."
            : " What is filed under the original later does not follow the copy."
        return try jsonString([
            "team_id": team.id,
            "team_name": team.name,
            "kind": kind.rawValue,
            "count": copies.count,
            "copies": copies,
            "linked_sources_shared": linkedSourcesShared,
            "course_sources_shared": courseSourcesShared,
            "cited_sources_shared": citedSourcesShared,
            "sources_not_shared": sourcesNotShared,
            "message": "Shared \(noun) with ‘\(team.name)’. \(detail)\(sourcesNote)",
            "guidance": "Sharing the same item again updates the team's copy rather than adding a second one. Team copies are listed when the team is the active library in ForeverLM; they never appear beside the learner's own rows. A Doc's sources travel with it by default, so a team copy resolves in the team's library; pass include_cited_sources: false to keep the cited papers and books behind.",
        ] as [String: Any])
    }

    // MARK: - Share… on a notebook

    /// What an assistant's call answers to the rights question
    /// (docs/teams-design.md, decision 22): its raw
    /// `rights_affirmed_by_learner` argument.
    struct SharingRightsAnswer {
        let raw: Any?

        init(_ raw: Any?) {
            self.raw = raw
        }

        /// Only a JSON true is the learner's yes; a 1, a "true" or a false is not.
        var isYes: Bool {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
    }

    /// The rights question before a share that copies sources to other
    /// people. Answered once by the learner, in any ForeverLM; until then an
    /// assistant's `rights_affirmed_by_learner: true` says it asked them in
    /// `SharingRightsAffirmation.assistantQuestion`'s words and they said yes,
    /// and records their answer as the Mac's sheet does. Anything else is
    /// refused with the question to ask. A row that answers already, the
    /// current version's or a later one's, is left as it is: the web and the
    /// iPhone pass true after writing their own, and a later version's row
    /// must not go back to this one's.
    func requireSharingRights(_ answer: SharingRightsAnswer) async throws {
        guard SharingRightsRow.needsAsking else { return }
        guard answer.isYes else {
            throw MCPError.invalidInput(SharingRightsAffirmation.assistantRefusal)
        }
        SharingRightsRow.affirm()
        await PreferenceStore.flushPendingWrites()
    }

    /// `share_notebook`: a notebook's Share… in one call. The checks come
    /// first — the notebook exists, the team named or found is one this
    /// account may invite to, a notebook in two teams has one named — then
    /// the rights question, then the store's one step
    /// (`StorageService.shareNotebook`) and the link Copy Invitation Link
    /// makes. `invitationLink` stands in for iCloud in tests.
    func shareNotebook(
        notebookID rawNotebookID: String?,
        rightsAnswer: SharingRightsAnswer,
        teamID rawTeamID: String?,
        invitationLink: (@Sendable (TeamRecord) async throws -> URL)? = nil
    ) async throws -> String {
        let notebookID = (rawNotebookID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notebookID.isEmpty else {
            throw MCPError.invalidInput("notebook_id is required. Use list_notebooks to find it.")
        }
        let trimmedTeamID = (rawTeamID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let teamID = trimmedTeamID.isEmpty ? nil : trimmedTeamID
        let storage = notebookFileStorage
        do {
            _ = try await storage.notebookShareTarget(notebookID, intoTeam: teamID)
        } catch {
            throw await notebookShareRefusal(error)
        }
        try await requireSharingRights(rightsAnswer)
        let share: NotebookTeamShare
        do {
            share = try await storage.shareNotebook(notebookID, intoTeam: teamID)
        } catch {
            throw await notebookShareRefusal(error)
        }
        await Self.teamsChanged(teamID: share.team.id)

        var link: URL?
        var linkProblem: String?
        do {
            if let invitationLink {
                link = try await invitationLink(share.team)
            } else {
                link = try await storage.invitationLink(for: share.team)
            }
        } catch {
            linkProblem = error.localizedDescription
        }
        let members = try await storage.loadTeamMembers(teamID: share.team.id)
            .filter { $0.acceptanceStatus != "removed" }
        let notebookTitle = try knowledgeStore().loadLearningGoal(notebookID)?.title ?? share.team.name
        let sources = share.sharedSourceCount == 1 ? "1 source" : "\(share.sharedSourceCount) sources"
        var message = share.createdTeam
            ? "Made the team ‘\(share.team.name)’ and shared ‘\(notebookTitle)’ into it with its \(sources); what is filed in the notebook from now on follows it into the team."
            : "‘\(notebookTitle)’ is in the team ‘\(share.team.name)’, with \(sources)."
        if link != nil {
            message += share.team.role == .owner
                ? " Anyone with invitation_link can join the team and edit its library: give it to the learner to pass on."
                : " invitation_link is the team's link as its owner left it: only people the owner admitted can open it."
        } else {
            message += " There is no invitation link yet (\(linkProblem ?? "iCloud has not shared the team")); it appears once iCloud has shared the team, so call share_notebook again in a moment."
        }
        return try jsonString([
            "team_id": share.team.id,
            "team_name": share.team.name,
            "created_team": share.createdTeam,
            "shared_sources": share.sharedSourceCount,
            "team_notebook_id": share.teamNotebookID,
            "invitation_link": link.map { $0.absoluteString as Any } ?? NSNull(),
            // An owner's link was opened to anyone who has it, with editing
            // (`invitationLink(for:)`), so whoever hands it on can say so.
            "link_opens_to_anyone": link != nil && share.team.role == .owner,
            "members": members.map { member -> [String: Any] in
                [
                    "name": member.displayName,
                    "email": member.email.flatMap { $0.isEmpty ? nil : $0 as Any } ?? NSNull(),
                    "role": member.role == .owner ? "owner" : (member.permission == .readWrite ? "editor" : "viewer"),
                    "accepted": member.acceptanceStatus == "accepted",
                ]
            },
            "message": message,
        ] as [String: Any])
    }

    /// The store's refusals of a notebook's share, in an assistant's words.
    private func notebookShareRefusal(_ error: Error) async -> Error {
        switch error {
        case NotebookShareError.notANotebook(let id):
            return MCPError.notFound("No Notebook with id \(id). Use list_notebooks.")
        case NotebookShareError.readOnly(let team):
            let owner = try? await notebookFileStorage.loadTeamMembers(teamID: team.id).first { $0.role == .owner }?.displayName
            return MCPError.invalidInput(readOnlyRefusal(team, action: "invite people to it", ownerName: owner))
        case let NotebookShareError.inSeveralTeams(title, teams):
            let named = teams.map { "‘\($0.name)’ (team_id \($0.id))" }.joined(separator: ", ")
            return MCPError.invalidInput("‘\(title)’ is in \(teams.count) teams: \(named). Pass team_id to say which team to invite people to.")
        case TeamError.unknownTeam(let id):
            return MCPError.notFound("No team with id \(id) on this Mac. Use list_teams.")
        case let error as KnowledgeStoreError:
            return MCPError.invalidInput(error.localizedDescription)
        default:
            return error
        }
    }

    /// A team made or filled from a chat: the Studio's list and Team
    /// Settings read the teams again, as after the sharing sheet.
    @MainActor
    private static func teamsChanged(teamID: String) async {
        if let studio = AppModelBridge.studio {
            await studio.loadTeams()
        }
        NotificationCenter.default.post(name: TeamSharingService.teamRosterDidChange, object: teamID)
    }

    // MARK: - Share requests

    func requestShare(teamID rawTeamID: String?, url rawURL: String?, title: String?, docID: String?) async throws -> String {
        let team = try await requireEditableTeam(rawTeamID, action: "ask it for a source")
        let url = (rawURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MCPError.invalidInput("url must be a web address (http or https).")
        }
        let store = try knowledgeStore()
        if let docID = docID?.trimmingCharacters(in: .whitespacesAndNewlines), !docID.isEmpty {
            guard try store.loadArtifact(docID) != nil else {
                throw MCPError.notFound("No Doc with id \(docID). Use list_docs.")
            }
        }
        let members = try await notebookFileStorage.loadTeamMembers(teamID: team.id)
        let me = members.first(where: { $0.isCurrentUser })
        let request: ShareRequestRecord
        do {
            request = try await notebookFileStorage.requestShare(
                teamID: team.id, url: url, title: title, artifactID: docID, requestedBy: me
            )
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let canFulfil = try await notebookFileStorage.fulfillableShareRequests().contains { $0.request.id == request.id }
        return try jsonString([
            "request": shareRequestPayload(request, canFulfil: canFulfil),
            "message": "Asked ‘\(team.name)’ for \(request.title ?? request.url). Every member sees the request; an editor whose own library holds the source answers it with fulfil_share_request.",
        ] as [String: Any])
    }

    func listShareRequests(teamID rawTeamID: String?, status rawStatus: String?) async throws -> String {
        let statusText = (rawStatus ?? "open").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let status: ShareRequestStatus?
        switch statusText {
        case "all": status = nil
        case "": status = .open
        default:
            guard let parsed = ShareRequestStatus(rawValue: statusText) else {
                throw MCPError.invalidInput("status must be one of: open, fulfilled, declined, all.")
            }
            status = parsed
        }
        var teams: [TeamRecord] = try await notebookFileStorage.loadTeams()
        if let rawTeamID, !rawTeamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let teamID = rawTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let team = teams.first(where: { $0.id == teamID }) else {
                throw MCPError.notFound("No team with id \(teamID) on this Mac. Use list_teams.")
            }
            teams = [team]
        }
        let fulfillable = Set(try await notebookFileStorage.fulfillableShareRequests().map(\.request.id))
        var payloads: [[String: Any]] = []
        for team in teams {
            for request in try await notebookFileStorage.loadShareRequests(teamID: team.id, status: status) {
                var payload = shareRequestPayload(request, canFulfil: fulfillable.contains(request.id))
                payload["team_name"] = team.name
                payloads.append(payload)
            }
        }
        return try jsonString([
            "count": payloads.count,
            "requests": payloads,
            "guidance": "A request with can_fulfil true is one this Mac can answer: fulfil_share_request shares My Library's copy into the team. decline_share_request closes one for everyone. Requests are made from a team Doc's cards or with request_share.",
        ] as [String: Any])
    }

    /// `rightsAnswer` is the call's `rights_affirmed_by_learner`, which the
    /// registry's dispatch always passes; a caller that is not an assistant's
    /// call passes nil and is not asked.
    func fulfilShareRequest(requestID rawID: String?, rightsAnswer: SharingRightsAnswer? = nil) async throws -> String {
        let id = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("request_id is required. Use list_share_requests.") }
        guard let pending = try await notebookFileStorage.loadShareRequest(id) else {
            throw MCPError.notFound("No share request with id \(id). Use list_share_requests.")
        }
        // Answering copies My Library's source into the team, so it waits on
        // the learner's word (docs/teams-design.md, decision 22): asked only
        // of a request this Mac would answer with its own copy, so a closed
        // one, a read-only team or a source not held is refused first.
        if let rightsAnswer,
           try await notebookFileStorage.fulfillableShareRequests().contains(where: { $0.request.id == id }) {
            try await requireSharingRights(rightsAnswer)
        }
        let me = try await notebookFileStorage.loadTeamMembers(teamID: pending.teamID).first(where: { $0.isCurrentUser })
        let request: ShareRequestRecord
        do {
            request = try await notebookFileStorage.fulfilShareRequest(id, resolvedBy: me)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "request": shareRequestPayload(request, canFulfil: false),
            "message": "Shared \(request.title ?? request.url) into the team; its copy is \(request.fulfilledSourceID ?? "in place") and the request is fulfilled for every member.",
        ] as [String: Any])
    }

    func declineShareRequest(requestID rawID: String?) async throws -> String {
        let id = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("request_id is required. Use list_share_requests.") }
        guard let pending = try await notebookFileStorage.loadShareRequest(id) else {
            throw MCPError.notFound("No share request with id \(id). Use list_share_requests.")
        }
        let me = try await notebookFileStorage.loadTeamMembers(teamID: pending.teamID).first(where: { $0.isCurrentUser })
        let request: ShareRequestRecord
        do {
            request = try await notebookFileStorage.declineShareRequest(id, resolvedBy: me)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "request": shareRequestPayload(request, canFulfil: false),
            "message": "Declined the request for \(request.title ?? request.url); every member sees it closed.",
        ] as [String: Any])
    }

    func shareRequestPayload(_ request: ShareRequestRecord, canFulfil: Bool) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": request.id,
            "team_id": request.teamID,
            "url": request.url,
            "title": request.title ?? NSNull(),
            "doc_id": request.artifactID ?? NSNull(),
            "status": request.status.rawValue,
            "requested_by": request.requestedByRecordName ?? NSNull(),
            "requested_by_name": request.requestedByDisplayName ?? NSNull(),
            "created_at": iso.string(from: request.createdAt),
            "updated_at": iso.string(from: request.updatedAt),
            "can_fulfil": request.isOpen && canFulfil,
        ]
        if let resolvedAt = request.resolvedAt { payload["resolved_at"] = iso.string(from: resolvedAt) }
        if let by = request.resolvedByRecordName { payload["resolved_by"] = by }
        if let name = request.resolvedByDisplayName { payload["resolved_by_name"] = name }
        if let copy = request.fulfilledSourceID { payload["team_copy_id"] = copy }
        return payload
    }

    private func shareNoun(_ kind: TeamShareKind, count: Int) -> String {
        switch kind {
        case .source: return count == 1 ? "1 source" : "\(count) sources"
        case .notebook: return count == 1 ? "1 Notebook" : "\(count) Notebooks"
        case .doc: return count == 1 ? "1 Doc" : "\(count) Docs"
        case .chat: return count == 1 ? "1 chat" : "\(count) chats"
        case .course: return count == 1 ? "1 course" : "\(count) courses"
        }
    }

    /// Every id must exist before anything is copied, so a typo in the third
    /// id does not leave two copies behind and an error.
    private func validateShareIDs(_ ids: [String], kind: TeamShareKind, store: KnowledgeStore) throws {
        var missing: [String] = []
        for id in ids {
            switch kind {
            case .source:
                if try !store.sourceExists(id) { missing.append(id) }
            case .notebook:
                guard let goal = try store.loadLearningGoal(id), goal.isNotebook else {
                    missing.append(id)
                    continue
                }
            case .doc:
                if try store.loadArtifact(id) == nil { missing.append(id) }
            case .chat:
                if try store.loadReviewSessionForSync(id) == nil { missing.append(id) }
            case .course:
                if try store.loadCourseForSync(id) == nil { missing.append(id) }
            }
        }
        guard missing.isEmpty else {
            let hint: String
            switch kind {
            case .source: hint = "Use list_sources or search_sources_semantic for source IDs."
            case .notebook: hint = "Use list_notebooks for Notebook IDs."
            case .doc: hint = "Use list_docs for Doc IDs."
            case .chat: hint = "Use get_review_sessions for chat IDs."
            case .course: hint = "Use list_courses for course IDs."
            }
            throw MCPError.notFound("No \(kind.rawValue) with id \(missing.joined(separator: ", ")). \(hint)")
        }
    }

    /// A chat filed in a Notebook is filed in that Notebook's team copy when the
    /// team has one; otherwise the snapshot is filed nowhere in particular.
    private func teamNotebookID(forChat sessionID: String, teamID: String, store: KnowledgeStore) throws -> String? {
        guard let session = try store.loadReviewSessionForSync(sessionID),
              let goalID = session.goalID, !goalID.isEmpty else { return nil }
        let candidate = TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: goalID)
        return try store.loadLearningGoal(candidate) != nil ? candidate : nil
    }

    // MARK: Notebook tasks

    func listNotebookTasks(notebookID: String?, status rawStatus: String?, assignee rawAssignee: String?) async throws -> String {
        let store = try knowledgeStore()
        let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let statusFilter = try rawStatus.map { try parseTaskStatus($0) }
        let team = try await teamContext(for: notebook)
        var tasks = try await notebookFileStorage.loadNotebookTasks(notebookID: notebook.id)
        if let statusFilter {
            tasks = tasks.filter { $0.status == statusFilter }
        }
        if let rawAssignee, !rawAssignee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let team else {
                throw MCPError.invalidInput(
                    "Notebook \(notebook.id) is not a team's, so its tasks have no assignees. Omit assignee."
                )
            }
            let recordName = try resolveAssignee(rawAssignee, members: team.members, teamName: team.team.name)
            tasks = tasks.filter { $0.assigneeRecordName == recordName }
        }

        var payload: [String: Any] = [
            "notebook_id": notebook.id,
            "notebook_title": notebook.title,
            "count": tasks.count,
            "tasks": tasks.map(notebookTaskPayload),
        ]
        if let team {
            payload["team"] = teamPayload(team.team, members: team.members)
            payload["guidance"] = "This Notebook is the team's, so its tasks are the team's board. Assign a task with the member's user_record_name from team.members (or \"me\" for this account); assignee_display_name is kept beside it so a task still reads well after a member leaves."
        } else {
            payload["team"] = NSNull()
            payload["guidance"] = "This Notebook is in My Library, so its tasks are the learner's own and carry no assignee."
        }
        return try jsonString(payload)
    }

    func createNotebookTask(
        notebookID: String?,
        title: String?,
        notes: String?,
        status rawStatus: String?,
        assigneeRecordName: String?,
        dueDate: String?,
        sourceID: String?,
        docID: String?
    ) async throws -> String {
        let store = try knowledgeStore()
        let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw MCPError.invalidInput("A task needs a title.")
        }
        let team = try await teamContext(for: notebook)
        if let team, !team.team.canEdit {
            throw MCPError.invalidInput(readOnlyRefusal(team.team, action: "add a task to its Notebook"))
        }
        let assignee = try resolveTaskAssignee(assigneeRecordName, team: team, notebookID: notebook.id)
        let dueAt = try parseDueDate(dueDate)
        let resolvedSourceID = try validatedTaskSourceID(sourceID, store: store)
        let resolvedDocID = try validatedTaskDocID(docID, store: store)
        let status = try rawStatus.map { try parseTaskStatus($0) } ?? .todo

        let task = NotebookTaskRecord(
            notebookID: notebook.id,
            teamID: notebook.teamID,
            title: trimmedTitle,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            status: status,
            assigneeRecordName: assignee?.recordName,
            assigneeDisplayName: assignee?.displayName,
            dueAt: dueAt,
            sourceID: resolvedSourceID,
            artifactID: resolvedDocID
        )
        let saved: NotebookTaskRecord
        do {
            saved = try await notebookFileStorage.saveNotebookTask(task)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "task": notebookTaskPayload(saved),
            "message": "Created task ‘\(saved.title)’ in Notebook ‘\(notebook.title)’" + (team.map { " for team ‘\($0.team.name)’" } ?? "") + ".",
        ] as [String: Any])
    }

    func updateNotebookTask(
        taskID: String?,
        title: String?,
        notes: String?,
        status rawStatus: String?,
        assigneeRecordName: String?,
        dueDate: String?,
        sourceID: String?,
        docID: String?
    ) async throws -> String {
        let store = try knowledgeStore()
        var task = try await requireNotebookTask(taskID)
        guard let notebook = try store.loadLearningGoal(task.notebookID) else {
            throw MCPError.notFound("Task \(task.id) belongs to Notebook \(task.notebookID), which no longer exists.")
        }
        let team = try await teamContext(for: notebook)
        if let team, !team.team.canEdit {
            throw MCPError.invalidInput(readOnlyRefusal(team.team, action: "change its tasks"))
        }

        // Omitted means "leave it alone". Only assignee_record_name and due_date
        // take "" as an explicit clear; a blank title is refused rather than saved.
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPError.invalidInput("title cannot be empty. Omit it to keep the current title.")
            }
            task.title = trimmed
        }
        if let notes { task.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let rawStatus { task.status = try parseTaskStatus(rawStatus) }
        if let assigneeRecordName {
            if assigneeRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                task.assigneeRecordName = nil
                task.assigneeDisplayName = nil
            } else {
                let assignee = try resolveTaskAssignee(assigneeRecordName, team: team, notebookID: notebook.id)
                task.assigneeRecordName = assignee?.recordName
                task.assigneeDisplayName = assignee?.displayName
            }
        }
        if let dueDate {
            // parseDueDate maps a blank string to nil, which is the clear.
            task.dueAt = try parseDueDate(dueDate)
        }
        if let sourceID {
            task.sourceID = try validatedTaskSourceID(sourceID, store: store)
        }
        if let docID {
            task.artifactID = try validatedTaskDocID(docID, store: store)
        }

        let saved: NotebookTaskRecord
        do {
            saved = try await notebookFileStorage.saveNotebookTask(task)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "task": notebookTaskPayload(saved),
            "message": "Updated task ‘\(saved.title)’.",
        ] as [String: Any])
    }

    func deleteNotebookTask(taskID: String?) async throws -> String {
        let store = try knowledgeStore()
        let task = try await requireNotebookTask(taskID)
        if let notebook = try store.loadLearningGoal(task.notebookID),
           let team = try await teamContext(for: notebook), !team.team.canEdit {
            throw MCPError.invalidInput(readOnlyRefusal(team.team, action: "delete its tasks"))
        }
        do {
            try await notebookFileStorage.deleteNotebookTask(task.id)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "deleted": true,
            "task_id": task.id,
            "title": task.title,
            "notebook_id": task.notebookID,
            "message": "Deleted task ‘\(task.title)’." + (task.teamID != nil ? " Every member of the team loses it." : ""),
        ] as [String: Any])
    }

    // MARK: Resolution helpers

    private struct TeamContext {
        let team: TeamRecord
        let members: [TeamMemberRecord]
    }

    private struct ResolvedAssignee {
        let recordName: String
        let displayName: String
    }

    /// The team a Notebook belongs to, with its roster; nil for My Library.
    private func teamContext(for notebook: LearningGoalRecord) async throws -> TeamContext? {
        guard let teamID = notebook.teamID else { return nil }
        guard let team = try await notebookFileStorage.loadTeam(teamID) else {
            throw MCPError.notFound(
                "Notebook \(notebook.id) belongs to team \(teamID), which is not on this Mac. Call list_teams."
            )
        }
        return TeamContext(team: team, members: try await notebookFileStorage.loadTeamMembers(teamID: teamID))
    }

    private func requireEditableTeam(_ rawTeamID: String?, action: String) async throws -> TeamRecord {
        let teamID = (rawTeamID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teamID.isEmpty else {
            throw MCPError.invalidInput("team_id is required. Use list_teams to find it.")
        }
        guard let team = try await notebookFileStorage.loadTeam(teamID) else {
            throw MCPError.notFound("No team with id \(teamID) on this Mac. Use list_teams.")
        }
        guard team.canEdit else {
            throw MCPError.invalidInput(readOnlyRefusal(team, action: action))
        }
        return team
    }

    /// Also refuses an import's notebook_id into such a team's Notebook
    /// (`notebookForImport`).
    func readOnlyRefusal(_ team: TeamRecord, action: String, ownerName: String? = nil) -> String {
        let owner = ownerName.map { "Its owner, \($0)," } ?? "Its owner"
        return "Team ‘\(team.name)’ is read-only for this account, so you cannot \(action). \(owner) gave this member read access only; ask them to change the permission in the team's sharing settings."
    }

    private func requireNotebookTask(_ rawTaskID: String?) async throws -> NotebookTaskRecord {
        let taskID = (rawTaskID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else {
            throw MCPError.invalidInput("task_id is required. Use list_notebook_tasks to find it.")
        }
        guard let task = try await notebookFileStorage.loadNotebookTask(taskID) else {
            throw MCPError.notFound("No task with id \(taskID). Use list_notebook_tasks.")
        }
        return task
    }

    private func parseTaskStatus(_ raw: String) throws -> NotebookTaskStatus {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let status = NotebookTaskStatus(rawValue: trimmed) else {
            throw MCPError.invalidInput(
                "status must be one of: \(NotebookTaskStatus.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return status
    }

    private func parseDueDate(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try parseScheduleDate(trimmed, calendar: .current, field: "due_date")
    }

    /// An assignee only means something in a team Notebook, and only for someone
    /// on the roster. "me" is this account's own membership.
    private func resolveTaskAssignee(
        _ raw: String?,
        team: TeamContext?,
        notebookID: String
    ) throws -> ResolvedAssignee? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let team else {
            throw MCPError.invalidInput(
                "Notebook \(notebookID) is not a team's, so its tasks cannot be assigned. Omit assignee_record_name, or share the Notebook with a team first."
            )
        }
        let recordName = try resolveAssignee(trimmed, members: team.members, teamName: team.team.name)
        let member = team.members.first { $0.userRecordName == recordName }
        return ResolvedAssignee(recordName: recordName, displayName: member?.displayName ?? recordName)
    }

    private func resolveAssignee(_ raw: String, members: [TeamMemberRecord], teamName: String) throws -> String {
        if raw.lowercased() == "me" {
            guard let me = members.first(where: { $0.isCurrentUser }) else {
                throw MCPError.invalidInput(
                    "This account's own membership of ‘\(teamName)’ is not in the roster on this Mac yet, so \"me\" cannot be resolved. Pass a user_record_name from list_teams, or open the team in ForeverLM to refresh its members."
                )
            }
            return me.userRecordName
        }
        guard members.contains(where: { $0.userRecordName == raw }) else {
            let known = members.map { "\($0.displayName) (\($0.userRecordName))" }.joined(separator: ", ")
            throw MCPError.invalidInput(
                "\(raw) is not a member of ‘\(teamName)’. Members: \(known.isEmpty ? "none on this Mac yet" : known). Pass a member's user_record_name, or \"me\"."
            )
        }
        return raw
    }

    private func validatedTaskSourceID(_ raw: String?, store: KnowledgeStore) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard try store.sourceExists(trimmed) else {
            throw MCPError.notFound("No source with id \(trimmed). Use list_sources or search_sources_semantic.")
        }
        return trimmed
    }

    private func validatedTaskDocID(_ raw: String?, store: KnowledgeStore) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard try store.loadArtifact(trimmed) != nil else {
            throw MCPError.notFound("No Doc with id \(trimmed). Use list_docs.")
        }
        return trimmed
    }

    // MARK: Payloads

    func teamPayload(_ team: TeamRecord, members: [TeamMemberRecord]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": team.id,
            "name": team.name,
            "role": team.role.rawValue,
            "permission": team.permission.rawValue,
            "can_edit": team.canEdit,
            // The owner's plan covers this team's members (docs/family-design.md).
            "family_plan": team.isFamily,
            "member_count": members.count,
            "members": members.map { member -> [String: Any] in
                var entry: [String: Any] = [
                    "user_record_name": member.userRecordName,
                    "display_name": member.displayName,
                    "role": member.role.rawValue,
                    "permission": member.permission.rawValue,
                    "acceptance_status": member.acceptanceStatus,
                    "is_current_user": member.isCurrentUser,
                ]
                if let email = member.email, !email.isEmpty { entry["email"] = email }
                return entry
            },
            "created_at": iso.string(from: team.createdAt),
            "joined_at": iso.string(from: team.joinedAt),
        ]
        if let shareURL = team.shareURL, !shareURL.isEmpty {
            payload["share_url"] = shareURL
        }
        return payload
    }

    /// The team fields every Notebook payload carries, so an assistant can tell
    /// a team Notebook from a personal one without a second call.
    func notebookTeamFields(_ goal: LearningGoalRecord, store: KnowledgeStore) -> [String: Any] {
        guard let teamID = goal.teamID else { return ["team_id": NSNull()] }
        var fields: [String: Any] = ["team_id": teamID]
        if let team = try? store.loadTeam(teamID) {
            fields["team_name"] = team.name
        }
        return fields
    }

    func notebookTaskPayload(_ task: NotebookTaskRecord) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": task.id,
            "notebook_id": task.notebookID,
            "team_id": task.teamID.map { $0 as Any } ?? NSNull(),
            "title": task.title,
            "notes": task.notes,
            "status": task.status.rawValue,
            "assignee_record_name": task.assigneeRecordName.map { $0 as Any } ?? NSNull(),
            "assignee_display_name": task.assigneeDisplayName.map { $0 as Any } ?? NSNull(),
            "due_date": task.dueAt.map { isoDateOnly($0) as Any } ?? NSNull(),
            "is_overdue": task.isOverdue,
            "source_id": task.sourceID.map { $0 as Any } ?? NSNull(),
            "doc_id": task.artifactID.map { $0 as Any } ?? NSNull(),
            "sort_order": task.sortOrder,
            "created_at": iso.string(from: task.createdAt),
            "updated_at": iso.string(from: task.updatedAt),
            "completed_at": task.completedAt.map { iso.string(from: $0) as Any } ?? NSNull(),
        ]
        if let createdBy = task.createdByRecordName {
            payload["created_by_record_name"] = createdBy
        }
        if let createdByName = task.createdByDisplayName {
            payload["created_by_display_name"] = createdByName
        }
        return payload
    }
}
