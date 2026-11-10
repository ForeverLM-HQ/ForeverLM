// Importing meeting artifacts: file identities, session keys, titles and descriptors.

import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    func importMeetingArtifacts(
        _ parsedFiles: [ParsedMeetingArtifact],
        groupTitle title: String,
        driveFolderURL: String?,
        localFolderPath: String?,
        discoveryOrigin: DiscoveryOrigin,
        emptyMessage: String,
        silent: Bool = false
    ) async throws {
        let trimmedDriveURL = driveFolderURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedDriveFolderID = trimmedDriveURL.flatMap { try? Self.googleDriveFolderID(from: $0) }
        let linkedDriveGroupID = requestedDriveFolderID.flatMap { folderID in
            meetingMetadata.first { _, existing in
                guard let existingURL = existing.driveFolderURL,
                      let existingFolderID = try? Self.googleDriveFolderID(from: existingURL) else { return false }
                return existingFolderID == folderID
            }?.key
        }
        // A Drive folder ID is the identity boundary. Two folders can share a
        // human title, so title matching must never merge their sessions.
        let importIdentityGroupID = linkedDriveGroupID
            ?? (requestedDriveFolderID == nil ? existingMeetingID(forTitle: title) : nil)
            ?? UUID().uuidString
        let groupID = canonicalMeetingGroupID(importIdentityGroupID)
        let previousImportMetadata = meetingMetadata[importIdentityGroupID]
        var importMetadata = previousImportMetadata ?? MeetingMetadata(title: title)
        // A plugin's folder title seeds a new series; it does not own the
        // learner's display name after that. Re-imports can arrive much later
        // (app activation, tab opening, another explicit folder pick), and the
        // provider will keep reporting its own unchanged folder name. Replacing
        // metadata.title here silently undid every Rename on the next import.
        // The stable group/folder ID is identity, while the stored title is
        // user-authored presentation state and therefore wins once present.
        if importMetadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            importMetadata.title = title
        }
        // Preserve an existing folder link when this import does not supply one.
        // A group can mix sources (e.g. Drive sessions plus a read.ai session);
        // a later non-Drive import must not clear the Drive folder URL, or the
        // group becomes unrefreshable because refresh paths skip null-URL groups.
        if let localFolderPath, !localFolderPath.isEmpty {
            importMetadata.localFolderPath = localFolderPath
        }
        if let trimmedDriveURL, !trimmedDriveURL.isEmpty {
            importMetadata.driveFolderURL = trimmedDriveURL
        }
        var metadata = meetingMetadata[groupID] ?? MeetingMetadata(title: title)
        if metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            metadata.title = title
        }
        let displayTitle = metadata.title ?? title
        if importIdentityGroupID == groupID {
            metadata.driveFolderURL = importMetadata.driveFolderURL
            metadata.localFolderPath = importMetadata.localFolderPath
        }
        let previousMetadata = meetingMetadata[groupID]
        if silent, Self.isMeetingGroupRemoved(groupID: groupID, metadata: metadata) {
            if !Self.hasRecordedMeetingGroupRemovalIdentity(groupID: groupID, metadata: metadata) {
                Self.recordMeetingGroupRemoval(groupID: groupID, metadata: metadata)
            }
            // Import work may already be in flight when the learner removes a
            // folder, and a provider rename must not evade the removal. The
            // durable group/folder identity wins before any source is written.
            if let previousMetadata, !previousMetadata.isHidden {
                var hidden = previousMetadata
                hidden.isHidden = true
                meetingMetadata[groupID] = hidden
                try await storage.saveMeetingGroup(name: groupID, metadata: hidden)
            }
            return
        }
        // An explicit import is the learner deliberately bringing this exact
        // group/folder back. Background refreshes never lift the tombstone.
        if !silent {
            Self.liftMeetingGroupRemoval(groupID: groupID, metadata: metadata)
        }
        if metadata.timezone == nil {
            metadata.timezone = TimeZone.current.identifier
        }
        // An explicit import is the user asking for this group back, so it lifts
        // the hidden flag `removeMeetingGroup` sets — the same way it lifts the
        // removal tombstone above. Background refreshes are silent and leave a
        // hidden group hidden.
        if !silent { metadata.isHidden = false }
        // The identity row needs its own write only when it is a retired alias.
        // For an active group, `metadata` below already carries these fields and
        // writes once after timezone/visibility have been finalized.
        if importIdentityGroupID != groupID, previousImportMetadata != importMetadata {
            meetingMetadata[importIdentityGroupID] = importMetadata
            try await storage.saveMeetingGroup(name: importIdentityGroupID, metadata: importMetadata)
        }
        if previousMetadata != metadata {
            meetingMetadata[groupID] = metadata
        }
        let insertedGroup = userMeetingGroupNames.insert(groupID).inserted
        if insertedGroup { saveUserMeetingGroupNames() }
        if previousMetadata != metadata {
            try await storage.saveMeetingGroup(name: groupID, metadata: metadata)
        }

        var grouped = Dictionary(
            grouping: Self.separatingEmbeddedTranscripts(in: parsedFiles),
            by: \.sessionKey
        )
        // A session the learner removed on its own is archived and its URL is
        // in `dismissed_sources`; `articles` holds active rows only, so to this
        // loop it looks like a session the folder has just gained, and the
        // upsert below (`status = excluded.status`) would stand the archived
        // row back up as active on the next refresh. A background refresh
        // leaves a removed session removed. An explicit import — the learner
        // choosing this folder again — is the one act that lifts a removal, so
        // it clears the tombstone first, with a synced deletion, and imports.
        let dismissedURLs = (try? await storage.loadDismissedSourceURLs()) ?? []
        if !dismissedURLs.isEmpty {
            for sessionKey in Array(grouped.keys) {
                let sourceURL = "meeting://\(groupID)/\(Self.percentEncodedMeetingPathComponent(sessionKey))"
                guard dismissedURLs.contains(sourceURL) else { continue }
                if silent {
                    grouped.removeValue(forKey: sessionKey)
                } else {
                    try await storage.prepareExplicitSourceReAdd(sourceURL)
                }
            }
        }
        guard !grouped.isEmpty else {
            if !silent { showToast(emptyMessage) }
            return
        }

        // One call for the whole import, before the write loop, so the session
        // rows land already named. Grouping is already fixed at this point, so a
        // failure here costs the topic and presenter, never the sessions
        // themselves — surface it and keep the date-based titles.
        //
        // A session filed while the call could not run (no model to run it on,
        // a failed request) kept the date its key spells, and used to keep it
        // for good: only new sessions were ever asked about. Every Nexus
        // session from 2026-10-11 on stayed "2026/10/11" while meeting tasks
        // waited for a paid model. Such a session is asked about again on each
        // refresh until a call has read its current file names once.
        var descriptors: [String: (title: String, presenter: String?)] = [:]
        let existingArticlesByURL = Dictionary(
            articles.map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var retriedSessionKeys: Set<String> = []
        var retryAttemptKeys: Set<String> = []
        let sessionsToDescribe = grouped.filter { sessionKey, artifacts in
            let url = "meeting://\(groupID)/\(Self.percentEncodedMeetingPathComponent(sessionKey))"
            guard let existing = existingArticlesByURL[url] else { return true }
            guard Self.meetingSessionNeedsDescriptor(
                storedTitle: existing.title,
                author: existing.author,
                sessionKey: sessionKey,
                groupTitle: displayTitle
            ) else { return false }
            let attemptKey = Self.meetingDescriptorAttemptKey(
                groupID: groupID,
                sessionKey: sessionKey,
                fileNames: artifacts.map(\.title)
            )
            guard !MeetingDescriptorAttempts.described.contains(attemptKey) else { return false }
            retriedSessionKeys.insert(sessionKey)
            retryAttemptKeys.insert(attemptKey)
            return true
        }
        if !sessionsToDescribe.isEmpty {
            do {
                descriptors = try await Self.meetingSessionDescriptors(for: sessionsToDescribe, groupTitle: displayTitle)
                // Read once with these file names: a session whose files carry
                // no topic is not asked about again until they change.
                MeetingDescriptorAttempts.described.formUnion(retryAttemptKeys)
            } catch {
                logger.error("Meeting session detail extraction failed: \(error.localizedDescription)")
                if !silent {
                    showToast("Could not read meeting topics: \(error.localizedDescription)")
                }
            }
        }

        let ownTranscriptionEnabled = Self.isMeetingOwnTranscriptionEnabled
        // Counted apart, because a refresh walks every session in the folder
        // whether or not anything about it moved. `importedSourceIDs` stays the
        // whole set: it feeds the icon backfill, which is about sessions that
        // still have no picture, not about sessions that arrived just now.
        var added = 0
        var updated = 0
        var importedSourceIDs: [String] = []
        // A plugin refresh can walk dozens of sessions. Keep its observable
        // state private until every durable write succeeds, then publish at
        // most one article snapshot and one artifact snapshot. Mutating either
        // collection once per session made List reconcile the whole Meetings
        // outline repeatedly while a silent tab-open refresh was still running,
        // which presented as rows jittering and flashing even when the provider
        // returned exactly the data already on screen.
        var stagedArticles = articles
        var stagedArtifactsBySourceID = meetingArtifactsBySourceId
        for (sessionKey, artifacts) in grouped {
            let sortedArtifacts = artifacts.sorted { $0.kind.sortRank < $1.kind.sortRank }
            let sourceURL = "meeting://\(groupID)/\(Self.percentEncodedMeetingPathComponent(sessionKey))"
            let descriptor = descriptors[sessionKey]
                ?? (title: Self.meetingSessionTitle(from: sessionKey, groupTitle: displayTitle), presenter: nil)
            let existingArticle = stagedArticles.first { $0.url == sourceURL }
            var article = existingArticle
                ?? StudioArticle(
                    url: sourceURL,
                    title: descriptor.title,
                    sourceType: .meeting,
                    discoveryOrigin: discoveryOrigin,
                    parentGroup: groupID
                )
            article.sourceType = .meeting
            // A session filed under its date takes the topic it was just read
            // for. A title the learner wrote never reaches here: it is not a
            // date, so the session was not asked about.
            if existingArticle != nil, retriedSessionKeys.contains(sessionKey),
               let described = descriptors[sessionKey] {
                article.title = described.title
            }
            // Only stamp the origin on sessions this import created. A group may
            // mix plugins (Drive sessions plus a read.ai session), and
            // overwriting on every re-import dragged existing sessions into
            // whichever plugin ran last, emptying the other tab.
            if article.discoveryOrigin == nil { article.discoveryOrigin = discoveryOrigin }
            article.parentGroup = groupID
            // Sessions used to be stored as "<series> - <topic>", which repeated
            // the row they already sit under on every line of the folder. Take
            // that prefix back off however this session is titled now: the
            // group's current and provider names, and the series its own key
            // spells out, which is the folder name from before a rename.
            article.title = Self.strippingMeetingSeriesPrefix(
                from: article.title,
                series: [displayTitle, title, Self.meetingSeriesTitle(from: sessionKey)].compactMap { $0 }
            )
            article.domain = displayTitle
            article.localFilePath = localFolderPath
            if let presenter = descriptor.presenter {
                article.author = presenter
            }
            if let occurredAt = Self.meetingDate(from: sessionKey) {
                article.dateAdded = occurredAt
            }
            let storedPriorArtifacts = (try? await storage.loadMeetingArtifacts(sourceID: article.id)) ?? []
            let priorArtifacts = stagedArtifactsBySourceID[article.id] ?? storedPriorArtifacts
            let generatedTranscriptID = SourceIdentity.stableID(for: "\(article.id):generated:transcript")
            let priorContent = existingArticle?.content
            let articleTitle = article.title
            let preparedContent = await Task.detached(priority: .utility) {
                let hasImportedTranscript = sortedArtifacts.contains(where: {
                    $0.kind == .transcript
                        && $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                })
                let preservedTranscript = hasImportedTranscript
                    ? nil
                    : MeetingContent.text(for: .transcript, in: priorContent)
                var sections = sortedArtifacts.compactMap { artifact -> String? in
                    guard let text = artifact.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return "## \(artifact.kind.label)\n\n\(text)"
                }
                if let preservedTranscript {
                    sections.insert("## Transcript\n\n\(preservedTranscript)", at: 0)
                }
                guard !sections.isEmpty else {
                    return (content: nil as String?, wordCount: nil as Int?, preservedTranscript: preservedTranscript)
                }
                let content = "# \(articleTitle)\n\n" + sections.joined(separator: "\n\n")
                return (content: content as String?, wordCount: content.split(separator: " ").count as Int?, preservedTranscript: preservedTranscript)
            }.value
            if preparedContent.content == nil {
                article.content = nil
                article.wordCount = nil
                article.state = .error
                article.errorMessage = ownTranscriptionEnabled
                    ? "No transcript, notes, or chat text found. Open the recording to generate its transcript."
                    : "Google Drive has no transcript, notes, or chat text for this session yet."
            } else {
                article.content = preparedContent.content
                article.wordCount = preparedContent.wordCount
                article.state = .ready
                article.errorMessage = nil
            }

            var sessionChanged = false
            if existingArticle != article {
                sessionChanged = true
                try await storage.saveSource(article, syncImmediately: true)
                if article.state == .ready { MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: article.id) }
                if let existingIndex = stagedArticles.firstIndex(where: { $0.id == article.id }) {
                    stagedArticles[existingIndex] = article
                } else {
                    stagedArticles.append(article)
                }
            }

            var savedArtifacts: [MeetingArtifact] = []
            var existingArtifacts: [String: MeetingArtifact] = [:]
            for artifact in priorArtifacts {
                existingArtifacts[artifact.id] = artifact
            }
            for (index, parsed) in sortedArtifacts.enumerated() {
                let artifact = MeetingArtifact(
                    id: SourceIdentity.stableID(for: "\(article.id):\(parsed.url.absoluteString):\(parsed.kind.rawValue)"),
                    sourceId: article.id,
                    groupId: groupID,
                    kind: parsed.kind,
                    title: parsed.title,
                    url: parsed.externalURL,
                    localFilePath: parsed.localFilePath,
                    mimeType: parsed.mimeType,
                    modifiedAt: parsed.modifiedAt,
                    sortIndex: index
                )
                if existingArtifacts[artifact.id] != artifact {
                    sessionChanged = true
                    try await storage.saveMeetingArtifact(artifact)
                }
                savedArtifacts.append(artifact)
            }
            if preparedContent.preservedTranscript != nil,
               let generated = existingArtifacts[generatedTranscriptID],
               !savedArtifacts.contains(where: { $0.id == generated.id }) {
                savedArtifacts.append(generated)
            }
            savedArtifacts.sort { $0.sortIndex < $1.sortIndex }
            stagedArtifactsBySourceID[article.id] = savedArtifacts
            importedSourceIDs.append(article.id)
            if existingArticle == nil {
                added += 1
            } else if sessionChanged {
                updated += 1
            }
        }

        // Fold sessions this folder filed a second time into the session that
        // holds their files now.
        //
        // A Drive file belongs to exactly one meeting, so a stored session that
        // shares a file with a session in this import *is* that meeting. Two
        // retired rules left such rows behind: the session key used to be built
        // from the group's display title, so renaming the folder re-keyed every
        // session in it, and a recursive listing used to walk into subfolders
        // that are series of their own, so a parent folder held a copy of every
        // session in the meetings folder nested inside it. The second case is
        // recognised by a file this folder no longer lists that another series
        // now owns — the folder gave it up, so the session goes with it.
        //
        // Matching on the file rather than on titles or dates is what makes the
        // fold safe: it can never merge two meetings that merely look alike, and
        // a folder holding no stale sessions does no work at all. Whatever the
        // stale row carried — schedule placements, Notebook membership, chats,
        // highlights — is handed to the surviving session before it is archived.
        var foldedSessionIDs: [String] = []
        let importedFiles = Set(parsedFiles.compactMap(Self.meetingFileIdentity))
        let importedOwnerByFile = Self.meetingArtifactFileOwners(
            sourceIDs: importedSourceIDs,
            artifacts: stagedArtifactsBySourceID
        )
        let otherSeriesOwnerByFile = Self.meetingArtifactFileOwners(
            sourceIDs: stagedArticles.lazy
                .filter { $0.sourceType == .meeting }
                .filter { $0.parentGroup.map(self.canonicalMeetingGroupID) != groupID }
                .map(\.id),
            artifacts: stagedArtifactsBySourceID
        )
        for stale in stagedArticles where stale.sourceType == .meeting
            && stale.parentGroup.map(canonicalMeetingGroupID) == groupID
            && !importedSourceIDs.contains(stale.id) {
            let files = stagedArtifactsBySourceID[stale.id] ?? []
            guard let canonicalID = files.lazy.compactMap({ artifact -> String? in
                guard let file = Self.meetingArtifactFileIdentity(artifact) else { return nil }
                if let owner = importedOwnerByFile[file] { return owner }
                // Only a file this listing no longer carries can move a session
                // out of this series; anything still in the folder stays here.
                guard !importedFiles.contains(file) else { return nil }
                return otherSeriesOwnerByFile[file]
            }).first(where: { $0 != stale.id }) else { continue }
            do {
                try await storage.archiveMeetingSessionDuplicate(stale.id, replacingWith: canonicalID)
                foldedSessionIDs.append(stale.id)
            } catch {
                logger.error("Folding duplicate meeting session failed: \(error.localizedDescription)")
            }
        }
        if !foldedSessionIDs.isEmpty {
            let folded = Set(foldedSessionIDs)
            stagedArticles.removeAll { folded.contains($0.id) }
            for sourceID in folded { stagedArtifactsBySourceID[sourceID] = nil }
            logger.notice("Folded \(folded.count) re-keyed meeting session(s) into their current session")
        }

        if stagedArticles != articles {
            articles = stagedArticles
        }
        if stagedArtifactsBySourceID != meetingArtifactsBySourceId {
            meetingArtifactsBySourceId = stagedArtifactsBySourceID
        }
        if !foldedSessionIDs.isEmpty {
            await reloadSourceRelationshipsAfterMerge()
        }

        // Artwork, once the artifacts are stored — the free sources read the
        // recording this loop just saved. Deliberately unawaited: an icon can
        // mean downloading a recording, and an import must not sit behind forty
        // of those before it reports what it brought in.
        let iconSourceIDs = importedSourceIDs
        Task { [weak self] in
            await self?.backfillIconsForImportedMeetings(sourceIDs: iconSourceIDs)
        }

        if !silent {
            // Every provider lands in the same place now, so there is no tab to
            // choose and no way to choose it wrongly. Picking one used to be a
            // real bug: the destination was hardcoded to Read AI, so importing a
            // Drive folder dropped the learner on an unrelated empty tab.
            //
            // Landing on a tab Studio unpinned for want of evidence: this import
            // is the evidence, so pin it rather than select a tab the tab bar
            // does not show.
            if autoUnpinnedIntegrationTabs.contains(.meetings) {
                showTab(.meetings)
            }
            sidebarTab = .meetings
            // Whichever provider this import came from, show it rather than
            // whatever provider was filtered to before.
            meetingProviderFilter = nil
            showToast(Self.meetingImportSummary(added: added, updated: updated))
        }
    }

    /// What an import actually brought in.
    ///
    /// Every import walks the whole folder, so the count of sessions it touched
    /// is just the size of the folder: refreshing a group of forty-two sessions
    /// reported "Imported 42 meeting sessions" every time, having imported none
    /// of them. Only sessions that did not exist before are imported. Ones whose
    /// files changed upstream — a transcript Google finished after the first
    /// import — are updates, and worth saying so. A refresh that found neither
    /// says that, rather than claiming an import that did not happen.
    nonisolated static func meetingImportSummary(added: Int, updated: Int) -> String {
        func sessions(_ count: Int) -> String {
            "\(count) meeting session\(count == 1 ? "" : "s")"
        }
        switch (added, updated) {
        case (0, 0): return "No new meeting sessions"
        case (0, _): return "Updated \(sessions(updated))"
        case (_, 0): return "Imported \(sessions(added))"
        default: return "Imported \(sessions(added)), updated \(updated)"
        }
    }

    /// Every Drive folder already standing as a meeting series of its own, apart
    /// from the one being imported. An import must not walk into these: they are
    /// their own identity boundary, and a parent folder that swept one up filed
    /// a second copy of every session inside it.
    func linkedGoogleDriveFolderIDs(excluding folderID: String) -> Set<String> {
        var ids: Set<String> = []
        for (groupID, metadata) in meetingMetadata {
            // A series the learner removed is no longer a boundary: its folder
            // is ordinary content of whatever contains it.
            guard !metadata.isHidden,
                  !Self.isMeetingGroupRemoved(groupID: groupID, metadata: metadata),
                  let url = metadata.driveFolderURL,
                  let id = try? Self.googleDriveFolderID(from: url),
                  id != folderID else { continue }
            ids.insert(id)
        }
        return ids
    }

    func existingMeetingID(forTitle title: String) -> String? {
        meetingMetadata.first { key, metadata in
            (metadata.title ?? key).caseInsensitiveCompare(title) == .orderedSame
        }.map { canonicalMeetingGroupID($0.key) }
    }

    /// Kind tokens Drive exports append (`… - Recording`) or that humans bracket
    /// inline (`2026-06-28 - [Recording] - Topic - Presenter`). Matched anywhere
    /// so a mid-string token still classifies; see `meetingSessionKey`.
    nonisolated private static let meetingKindTokenPattern =
        #"(?i)(?:\s*[-–—]\s*|^)\[?(chat|notes by gemini|meeting notes|notes|recording|transcript)\]?(?=\s*[-–—]|\s*$)"#

    /// The bracketed kind token in a name, if any (`[Notes]` -> "notes").
    nonisolated private static func bracketedKindToken(in stem: String) -> String? {
        guard let range = stem.range(of: #"\[([^\]]+)\]"#, options: .regularExpression) else { return nil }
        return stem[range]
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    /// Promote the transcript Google buries inside a Meet notes Doc into its
    /// own artifact.
    ///
    /// Meet writes one Doc holding all three of Gemini's tabs — quick notes,
    /// full notes, and the verbatim transcript — so classification by file name
    /// can only ever call the whole thing "notes". The session then showed Notes
    /// and Recording, the reader saw no transcript artifact, and it started a
    /// paid speech-to-text run to reproduce text that had shipped in the file.
    /// Splitting here — before grouping, so every part lands on the same session
    /// key — gives the session a real transcript artifact and stops that
    /// duplicate work.
    ///
    /// Both notes tabs are kept. They are separate things Gemini wrote about the
    /// same meeting, and the notes artifact carries them as two headed sections
    /// rather than dropping either.
    ///
    /// A session that already carries a standalone transcript file keeps it and
    /// only has the redundant copy trimmed out of its notes: an explicit
    /// artifact always outranks one recovered from inside another file.
    nonisolated static func separatingEmbeddedTranscripts(
        in parsed: [ParsedMeetingArtifact]
    ) -> [ParsedMeetingArtifact] {
        let sessionsWithTranscriptFile = Set(
            parsed.filter { $0.kind == .transcript }.map(\.sessionKey)
        )
        return parsed.flatMap { artifact -> [ParsedMeetingArtifact] in
            guard artifact.kind == .notes else { return [artifact] }
            let split = GoogleMeetNotesSplit.split(artifact.text)

            func part(_ kind: MeetingArtifactKind, _ text: String?) -> ParsedMeetingArtifact {
                ParsedMeetingArtifact(
                    url: artifact.url,
                    title: artifact.title,
                    sessionKey: artifact.sessionKey,
                    kind: kind,
                    text: text,
                    externalURL: artifact.externalURL,
                    localFilePath: artifact.localFilePath,
                    mimeType: artifact.mimeType,
                    modifiedAt: artifact.modifiedAt
                )
            }

            var separated = [part(.notes, split.notes)]
            if let transcript = split.transcript,
               !sessionsWithTranscriptFile.contains(artifact.sessionKey) {
                separated.append(part(.transcript, transcript))
            }
            return separated
        }
    }

    nonisolated static func meetingArtifactKind(fileName: String, mimeType: String?) -> MeetingArtifactKind? {
        let nsName = fileName as NSString
        let lower = nsName.deletingPathExtension.lowercased()
        let ext = nsName.pathExtension.lowercased()
        // A bracketed token is an explicit declaration, not an inferred label.
        if let token = bracketedKindToken(in: lower) {
            switch token {
            case "transcript": return .transcript
            case "notes", "meeting notes", "notes by gemini": return .notes
            case "chat": return .chat
            case "recording": return .recording
            default: break
            }
        }
        // Google's own Meet exports use unbracketed structural suffixes such
        // as "- Transcript", "- Notes by Gemini", and "- Recording". The
        // session-key parser already recognizes these tokens; classification
        // must use the same evidence or transcript Docs become generic
        // attachments and never appear as the meeting transcript.
        if let regex = try? NSRegularExpression(pattern: meetingKindTokenPattern),
           let match = regex.firstMatch(
               in: lower,
               range: NSRange(lower.startIndex..<lower.endIndex, in: lower)
           ),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: lower) {
            switch String(lower[range]) {
            case "transcript": return .transcript
            case "notes", "meeting notes", "notes by gemini": return .notes
            case "chat": return .chat
            case "recording": return .recording
            default: break
            }
        }
        if lower.range(of: #"\btranscript\b"#, options: .regularExpression) != nil {
            return .transcript
        }
        if lower.range(of: #"\b(notes by gemini|meeting notes)\b"#, options: .regularExpression) != nil {
            return .notes
        }
        if ext == "vtt" || ext == "srt" || ext == "ttml" {
            return .transcript
        }
        if ext == "sbv" { return .chat }
        if ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"].contains(ext)
            || mimeType?.hasPrefix("audio/") == true
            || mimeType?.hasPrefix("video/") == true {
            return .recording
        }
        return nil
    }

    nonisolated private static func isSupportedMeetingAttachment(fileName: String, mimeType: String?) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["txt", "md", "markdown", "pdf", "docx", "gdoc", "html", "htm"].contains(ext) {
            return true
        }
        guard let mimeType else { return false }
        return [
            "text/plain",
            "text/markdown",
            "text/html",
            "application/pdf",
            "application/vnd.google-apps.document",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ].contains(mimeType)
    }

    nonisolated static func googleDriveFolderID(from value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceError.invalidURL }
        if !trimmed.contains("/") && !trimmed.contains(" ") { return trimmed }
        guard let url = URL(string: trimmed) else { throw SourceError.invalidURL }
        let parts = url.pathComponents
        if let folderIndex = parts.firstIndex(of: "folders") {
            let idIndex = parts.index(after: folderIndex)
            if parts.indices.contains(idIndex), !parts[idIndex].isEmpty { return parts[idIndex] }
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { throw SourceError.invalidURL }
        return id
    }

    nonisolated static func fetchAuthenticatedGoogleDriveMeetingArtifacts(
        folderID: String,
        accountID: String? = nil,
        excludingFolderIDs: Set<String> = []
    ) async throws -> [ParsedMeetingArtifact] {
        let files = try await GoogleDriveService.shared.listFolderItemsRecursively(
            folderID: folderID,
            accountID: accountID,
            excludingFolderIDs: excludingFolderIDs
        )
        var artifacts: [ParsedMeetingArtifact] = []
        for file in files where !file.isFolder {
            let kind = meetingArtifactKind(fileName: file.name, mimeType: file.effectiveMimeType)
            guard kind != nil || isSupportedMeetingAttachment(fileName: file.name, mimeType: file.effectiveMimeType) else {
                continue
            }
            let artifactKind = kind ?? .attachment
            let text = try await readAuthenticatedGoogleDriveTextArtifact(file, kind: artifactKind)
            let stem = (file.name as NSString).deletingPathExtension
            artifacts.append(ParsedMeetingArtifact(
                url: URL(string: file.webURL) ?? URL(string: "https://drive.google.com/file/d/\(file.id)/view")!,
                title: stem.isEmpty ? file.name : stem,
                sessionKey: meetingSessionKey(from: stem),
                kind: artifactKind,
                text: text,
                externalURL: file.webURL,
                localFilePath: nil,
                mimeType: meetingMimeType(fileName: file.name, mimeType: file.effectiveMimeType),
                modifiedAt: file.modifiedAt
            ))
        }
        return artifacts
    }

    nonisolated private static func readAuthenticatedGoogleDriveTextArtifact(
        _ file: GoogleDriveFile,
        kind: MeetingArtifactKind
    ) async throws -> String? {
        guard kind == .transcript || kind == .notes || kind == .chat || kind == .attachment else {
            return nil
        }
        guard let raw = try await GoogleDriveService.shared.downloadText(file: file) else { return nil }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ext == "ttml", let extracted = try? SourceService.extractTextFromTTMLContent(raw) {
            return extracted
        }
        if ext == "html" || ext == "htm" {
            return raw
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    /// Collapse every file belonging to one real meeting onto a single key.
    ///
    /// Drive folders mix two naming conventions for the same series: the Meet
    /// export (`Acme Lab Nexus - 2026/06/21 09:00 PDT - Recording`) and
    /// hand-named uploads (`2026-06-28 - [Recording] - Topic - Presenter`). Both
    /// must land on one session, or a meeting fans out into a row per file.
    ///
    /// The key is canonicalised to `<series> - yyyy/MM/dd`: kind tokens are
    /// stripped wherever they appear, and the time-of-day is dropped so a
    /// timestamped export folds together with a date-only upload for the same
    /// day. Names with no parseable date fall back to the cleaned stem.
    ///
    /// Everything the key is made of comes out of the file's own name. Nothing
    /// mutable is allowed in: the key used to fall back to the group's display
    /// title whenever a file led with its date (`2026-08-30 - [Recording] - …`,
    /// the hand-named convention), which made session identity a function of a
    /// name the learner can edit. Renaming the folder therefore re-keyed every
    /// session in it, and the next refresh imported all of them a second time —
    /// forty-two sessions became eighty-four, each one twice. A date-led file
    /// keys on its date alone; the group id already says which series it is.
    nonisolated static func meetingSessionKey(from fileStem: String) -> String {
        let key = fileStem
            .replacingOccurrences(of: meetingKindTokenPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—\t"))
        // A name that is nothing but a kind marker still has to key on
        // something of its own, so the untouched stem is all there is.
        guard !key.isEmpty else { return fileStem }
        guard let date = meetingDate(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy/MM/dd"
        let day = formatter.string(from: date)
        guard let series = meetingSeriesTitle(from: key), !series.isEmpty else { return day }
        return "\(series) - \(day)"
    }

    /// The session key encoded in a `meeting://<groupID>/<sessionKey>` source URL.
    /// The session key of a `meeting://<group id>/<session key>` URL, percent-
    /// decoded. Parsed by hand: a group id such as
    /// `zoom:examplefellowship.zoom.us` carries a colon that `URLComponents`
    /// reads as a port and refuses the whole URL, which left every session of
    /// that series without a key here — and so without the start its key
    /// spells (`MeetingCalendarEvent.knownStart`).
    nonisolated static func meetingSessionKey(fromSourceURL url: String) -> String? {
        let prefix = "meeting://"
        guard url.hasPrefix(prefix) else { return nil }
        let rest = url.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let encoded = String(rest[rest.index(after: slash)...])
        let path = encoded.removingPercentEncoding ?? encoded
        return path.isEmpty ? nil : path
    }

    /// Resolve the topic and presenter for each session in one AI call.
    ///
    /// Meeting file names are hand-rolled and endlessly varied — the series may
    /// lead or follow the date, kind markers may be bracketed or trailing, and
    /// the presenter is just a name at the end that has to be told apart from
    /// the rest of the topic. That is a reading task, not a parsing one.
    ///
    /// Session *identity* stays deterministic: grouping is done by
    /// `meetingSessionKey` before this runs, so a failed or slow call can never
    /// change which files belong to which session — only how the session reads.
    nonisolated static func meetingSessionDescriptors(
        for grouped: [String: [ParsedMeetingArtifact]],
        groupTitle: String
    ) async throws -> [String: (title: String, presenter: String?)] {
        guard let config = KeychainService.resolveConfig(for: .meetingSessionDetails) else {
            throw AIError.missingAPIKey
        }
        let sessions = grouped.map { key, artifacts in
            (
                id: key,
                fileNames: artifacts.map(\.title),
                notesExcerpt: artifacts.first { $0.kind == .notes }?.text
            )
        }
        // AIService is an actor, so the call runs off the main actor.
        let details = try await AIService().extractMeetingSessionDetails(
            seriesTitle: groupTitle,
            sessions: sessions,
            config: config
        )
        return grouped.keys.reduce(into: [:]) { result, key in
            let detail = details[key]
            let topic = detail?.title ?? ""
            result[key] = (
                title: topic.isEmpty ? meetingSessionTitle(from: key, groupTitle: groupTitle) : topic,
                presenter: detail?.presenter
            )
        }
    }

    /// The file an artifact was read from, as the one thing about it that two
    /// sessions can only share by being the same meeting. A Drive artifact is
    /// its file's URL; a folder import is its path on disk.
    nonisolated static func meetingArtifactFileIdentity(_ artifact: MeetingArtifact) -> String? {
        meetingFileIdentity(url: artifact.url, localFilePath: artifact.localFilePath)
    }

    /// The same identity, read off a file an import has just parsed.
    nonisolated static func meetingFileIdentity(_ parsed: ParsedMeetingArtifact) -> String? {
        meetingFileIdentity(url: parsed.externalURL, localFilePath: parsed.localFilePath)
    }

    nonisolated private static func meetingFileIdentity(
        url: String?,
        localFilePath: String?
    ) -> String? {
        let url = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url, !url.isEmpty { return url }
        let path = localFilePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty { return "file:\(path)" }
        return nil
    }

    /// Which session currently owns each file, across the sessions an import
    /// just wrote. A file named by two of them cannot decide anything, so it is
    /// dropped rather than folding a session into an arbitrary one of the pair.
    nonisolated static func meetingArtifactFileOwners(
        sourceIDs: [String],
        artifacts: [String: [MeetingArtifact]]
    ) -> [String: String] {
        var owners: [String: String] = [:]
        var contested: Set<String> = []
        for sourceID in sourceIDs {
            for artifact in artifacts[sourceID] ?? [] {
                guard let file = meetingArtifactFileIdentity(artifact) else { continue }
                if let existing = owners[file], existing != sourceID {
                    contested.insert(file)
                    continue
                }
                owners[file] = sourceID
            }
        }
        for file in contested { owners[file] = nil }
        return owners
    }

    /// A session's own name, with the series it sits under taken back out.
    ///
    /// The series is the row this session is filed under, so repeating it in
    /// every child read as "Acme Lab Nexus — Acme Lab Nexus - Journal Club
    /// - …" down the whole folder. The session is named for what happened in
    /// it; when the file names carry nothing but a series and a date, the date
    /// is the honest answer.
    nonisolated static func meetingSessionTitle(from sessionKey: String, groupTitle: String) -> String {
        let stripped = strippingMeetingSeriesPrefix(from: sessionKey, series: [groupTitle])
        return stripped.isEmpty ? sessionKey : stripped
    }

    /// Whether a filed session still reads as nothing but when it happened,
    /// with no presenter: the name an import gives a session it could not
    /// read the topic of. A title the learner or a provider wrote, or a
    /// session that has a presenter, has been read and is left alone.
    nonisolated static func meetingSessionNeedsDescriptor(
        storedTitle: String,
        author: String?,
        sessionKey: String,
        groupTitle: String
    ) -> Bool {
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let series = [groupTitle, meetingSeriesTitle(from: sessionKey)].compactMap { $0 }
        let stored = strippingMeetingSeriesPrefix(from: storedTitle, series: series)
        return stored == sessionKey
            || stored == meetingSessionTitle(from: sessionKey, groupTitle: groupTitle)
            || isRawMeetingDateTitle(stored)
    }

    /// One session read with one set of file names, so a session is asked
    /// about again only when its files change.
    nonisolated static func meetingDescriptorAttemptKey(
        groupID: String,
        sessionKey: String,
        fileNames: [String]
    ) -> String {
        ([groupID, sessionKey] + fileNames.sorted()).joined(separator: "\u{1F}")
    }

    /// What a session row prints where its name goes.
    ///
    /// `day` is set when `text` is a formatted day: the metadata line then
    /// prints `time` alone instead of saying the same day twice. `time` is the
    /// instant whose clock reading that line shows, and it is nil when nothing
    /// trustworthy says when on that day the meeting ran.
    struct MeetingSessionRowTitle: Equatable {
        var text: String
        var day: Date?
        var time: Date?
    }

    /// The row title for a session filed under `groupTitle`.
    ///
    /// Sessions arrive titled three ways: `<series> - <date time>` from the
    /// folder importers and MCP, `<shortened series> - <date time>` when the
    /// provider's topic was trimmed ("Alan <> Zara" under a series called
    /// "Alan <> Zara standup") or spelled the way a file name must spell it
    /// ("Alan __ Zara"), or a real topic the learner or the provider wrote.
    /// The first two are the same thing — a meeting named for nothing but
    /// when it happened — and read as one format: the day, spelled out.
    /// The day comes from the title itself when it carries one, because a
    /// session pushed in a day late without `occurred_at` is still the meeting
    /// its title names, not the moment it was filed. The time comes from the
    /// title too; a title with only a day borrows the filing time when that
    /// fell on the same day, and otherwise the row shows no time at all rather
    /// than midnight.
    nonisolated static func meetingSessionRowTitle(
        storedTitle: String,
        groupTitle: String,
        dateAdded: Date,
        calendar: Calendar = .current
    ) -> MeetingSessionRowTitle {
        var series = [groupTitle]
        if let own = meetingSeriesTitle(from: storedTitle), isSeriesVariant(own, of: groupTitle) {
            series.append(own)
        }
        let remainder = strippingMeetingSeriesPrefix(from: storedTitle, series: series)
        guard isRawMeetingDateTitle(remainder) else {
            return MeetingSessionRowTitle(text: remainder, day: nil, time: nil)
        }
        let day = meetingDate(from: remainder) ?? dateAdded
        let time: Date?
        if remainder.range(of: #"\d{1,2}[:.]\d{2}"#, options: .regularExpression) != nil {
            time = day
        } else if calendar.isDate(dateAdded, inSameDayAs: day) {
            time = dateAdded
        } else {
            time = nil
        }
        return MeetingSessionRowTitle(text: day.formatted(date: .long, time: .omitted), day: day, time: time)
    }

    /// True when the remainder of a session title is only a date, with or
    /// without a time and zone: "2026/05/10", "2026/05/10 08:00 PDT".
    nonisolated static func isRawMeetingDateTitle(_ value: String) -> Bool {
        value.range(of: #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}[\s.:0-9]*[A-Z]{0,4}$"#, options: .regularExpression) != nil
    }

    /// Whether one series name is the other cut short at a word boundary:
    /// "Alan <> Zara" against "Alan <> Zara standup". A provider renames its
    /// recurring meeting, or a learner renames the series here, and the titles
    /// already stored keep the older spelling. The two are compared as Zoom
    /// spells them in a file name, because a recording folder cannot carry
    /// `<>` and its sessions arrive as "Alan __ Zara" under a series called
    /// "Alan <> Zara standup" — which read as the raw title in the middle of
    /// a folder of dates until 2026-09-28 (the product owner: "can you please make sure
    /// these zoom meetings show up consistently?"). Anything shorter than a
    /// few characters is not a name, it is a coincidence.
    nonisolated static func isSeriesVariant(_ candidate: String, of groupTitle: String) -> Bool {
        let first = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let second = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard first.count >= 3, second.count >= 3 else { return false }
        let (short, long) = first.count < second.count ? (first, second) : (second, first)
        // The spelling maps one character to one, so an offset into the
        // file-name form is the same offset into the title.
        let shortForm = meetingTitleFileNameSpelling(short)
        let longForm = meetingTitleFileNameSpelling(long)
        if shortForm == longForm { return true }
        guard longForm.hasPrefix(shortForm) else { return false }
        let boundary = long[long.index(long.startIndex, offsetBy: short.count)]
        return boundary == " " || "-–—:".contains(boundary)
    }

    /// A meeting title the way Zoom writes it into a file or folder name:
    /// every character a file name cannot carry becomes `_`, so "Alan <>
    /// Zara" is "Alan __ Zara" on disk.
    nonisolated static func meetingTitleFileNameSpelling(_ title: String) -> String {
        let forbidden: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
        return String(title.map { forbidden.contains($0) ? "_" : $0 })
    }

    /// Remove a leading `<series> - ` from a session title.
    ///
    /// Only a prefix this app wrote is removed: the match is anchored, spans a
    /// whole series name, and has to leave something behind. A session the
    /// learner renamed to something that merely mentions the series keeps it,
    /// because the prefix has to be followed by the separator to count.
    nonisolated static func strippingMeetingSeriesPrefix(
        from title: String,
        series candidates: [String]
    ) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = true
        while stripped {
            stripped = false
            for candidate in candidates {
                let series = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !series.isEmpty,
                      result.count > series.count,
                      result.lowercased().hasPrefix(series.lowercased()) else { continue }
                // The separator is what proves this was a prefix rather than the
                // opening words of the session's own name.
                let afterSeries = result.dropFirst(series.count).drop { $0 == " " }
                guard let separator = afterSeries.first, "-–—".contains(separator) else { continue }
                let remainder = String(afterSeries.dropFirst())
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
                guard !remainder.isEmpty else { continue }
                result = remainder
                stripped = true
            }
        }
        return result
    }

    /// Extract the recurring-series name from a session key by stripping the
    /// trailing date/time portion, e.g. "Acme Lab Nexus - 2026/05/10 08:00 PDT"
    /// -> "Acme Lab Nexus". Returns nil when the key has no date or nothing
    /// precedes it.
    nonisolated static func meetingSeriesTitle(from sessionKey: String) -> String? {
        let pattern = #"(\d{4})[/-](\d{1,2})[/-](\d{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sessionKey, range: NSRange(sessionKey.startIndex..<sessionKey.endIndex, in: sessionKey)),
              let range = Range(match.range, in: sessionKey) else { return nil }
        let prefix = String(sessionKey[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—\t"))
        return prefix.isEmpty ? nil : prefix
    }

    nonisolated static func meetingDate(from sessionKey: String) -> Date? {
        let pattern = #"(\d{4})[/-](\d{1,2})[/-](\d{1,2})(?:\s+(\d{1,2})[:.](\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sessionKey, range: NSRange(sessionKey.startIndex..<sessionKey.endIndex, in: sessionKey)),
              match.numberOfRanges >= 4,
              let yearRange = Range(match.range(at: 1), in: sessionKey),
              let monthRange = Range(match.range(at: 2), in: sessionKey),
              let dayRange = Range(match.range(at: 3), in: sessionKey),
              let year = Int(sessionKey[yearRange]),
              let month = Int(sessionKey[monthRange]),
              let day = Int(sessionKey[dayRange]) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        if match.numberOfRanges >= 6,
           let hourRange = Range(match.range(at: 4), in: sessionKey),
           let minuteRange = Range(match.range(at: 5), in: sessionKey) {
            components.hour = Int(sessionKey[hourRange])
            components.minute = Int(sessionKey[minuteRange])
        }
        return components.date
    }

    nonisolated private static func meetingMimeType(fileName: String, mimeType: String?) -> String? {
        if let mimeType, !mimeType.isEmpty { return mimeType }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        case "gdoc": return "application/vnd.google-apps.document"
        case "txt": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "vtt": return "text/vtt"
        case "srt": return "application/x-subrip"
        case "ttml": return "application/ttml+xml"
        default: return nil
        }
    }

    nonisolated static func percentEncodedMeetingPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? UUID().uuidString
    }

}

/// Sessions whose topic has been read with the file names they have now, for
/// this launch. A session filed under its date is asked about on each refresh
/// until one call has read it; this keeps a session whose files carry no topic
/// at all from being sent again every few minutes. Nothing here is stored: a
/// relaunch reads each such session once more.
@MainActor
enum MeetingDescriptorAttempts {
    static var described: Set<String> = []
}
