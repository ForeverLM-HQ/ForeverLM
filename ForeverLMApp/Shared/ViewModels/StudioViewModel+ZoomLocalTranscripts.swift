#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import os

/// Zoom's desktop client writes a caption transcript of every meeting it
/// records or captions on this Mac, beside the local recording, as
/// `~/Documents/Zoom/<topic> <yyyy-MM-dd> <HH:mm>(GMT-7:00).txt`. A Basic Zoom
/// account has no cloud recording and so never mails a "Meeting assets are
/// ready" notice, which made these files the only transcript the standups on
/// such an account ever produced — and nothing read them. This watches the
/// folder and files each transcript into the recurring series its topic
/// names, the way the recordings mailbox files a cloud recording.
///
/// The product owner (2026-09-12): "make sure this zoom transcript ingest is done
/// automatically."
///
/// The caption file only exists when Save Captions was on for that meeting.
/// The recording beside it always does — `<yyyy-MM-dd HH.mm.ss> <topic>/`
/// with the converted `audio*.m4a` and `video*.mp4`, or the raw
/// `double_click_to_convert_*.zoom` files Zoom leaves when it was quit before
/// converting. Four of the five standups in the folder on 2026-09-19 had a
/// recording and no caption file, and none of them was found. So a recording
/// folder with no caption file is filed too: as a session carrying the
/// recording, transcribed by ForeverLM once Zoom has converted it. When Zoom
/// has not, only Zoom can: it alone reads a raw `.zoom` file, and it asks
/// "Files from unknown sources" before converting one its meeting did not
/// convert on the spot. The Meetings tab and Settings › Sources list each
/// waiting recording with **Convert in Zoom** and **Ignore**, for a meeting
/// that did not happen. When the learner has let ForeverLM use
/// Accessibility, ForeverLM also converts a waiting recording by itself and
/// presses Convert Anyway on Zoom's dialog, so the row is only seen for a
/// recording Zoom could not convert; without that permission nothing is
/// opened in the background, because the dialog would then be the learner's
/// at every launch.
///
/// The product owner (2026-09-19): "i want to make sure that these meeting transcripts
/// on my mac are automatically found". The product owner (2026-09-20), on Zoom's
/// "Files from unknown sources" dialog opening at every launch over the
/// recording of a meeting he had ended because it did not happen: "it keeps
/// trying to ingest it … I wonder if we should handle that somehow" — and
/// yes to a surfaced version over a background one. The product owner (2026-09-25):
/// "i always have to give permission for this in zoom; can you auto give
/// permission?"
extension StudioViewModel {

    /// A recording only Zoom can convert, waiting for the learner's word.
    struct ZoomLocalRecordingAwaitingConversion: Identifiable, Equatable, Sendable {
        let folder: ZoomLocalRecordingFolder
        /// The meeting's title as the library knows it, or the folder's own
        /// file-safe spelling when no series matches.
        let title: String
        var id: String { folder.path }
    }

    /// One transcript file Zoom wrote, as its name describes it.
    struct ZoomLocalTranscriptFile: Equatable, Sendable {
        let path: String
        let topic: String
        let startedAt: Date
        let modifiedAt: Date
    }

    /// Zoom appends to the caption file while the meeting runs and its
    /// modification date moves with every line; a file is read only once it has
    /// been still for this long, so a meeting is filed whole, after it ends.
    nonisolated static let zoomLocalTranscriptSettleInterval: TimeInterval = 120

    // MARK: - Folder

    /// Where Zoom saves captions is a Zoom setting, and its default —
    /// `~/Documents/Zoom` — is not always somewhere the transcripts should
    /// live: `~/Documents` can be a symlink into cloud storage someone else
    /// controls, so leaving Zoom at its default files every meeting there.
    /// Moving Zoom's folder has to be possible without ingestion
    /// silently stopping, so the folder is a preference and both it and the
    /// default are watched.
    ///
    /// Machine-local on purpose: a path is a fact about one Mac, so this is
    /// plain `UserDefaults` and never `SyncedStorage`, which would push this
    /// Mac's path onto the other one.
    static let zoomLocalTranscriptFolderKey = "studio.zoomLocalTranscriptFolder"

    nonisolated static var zoomLocalTranscriptCustomFolder: String? {
        let stored = UserDefaults.standard.string(forKey: zoomLocalTranscriptFolderKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return (stored as NSString).expandingTildeInPath
    }

    nonisolated static func zoomLocalTranscriptDefaultFolder(homeDir: String) -> String {
        (homeDir as NSString).appendingPathComponent("Documents/Zoom")
    }

    nonisolated static func zoomLocalTranscriptRoots(
        homeDir: String,
        customFolder: String? = zoomLocalTranscriptCustomFolder
    ) -> [String] {
        // The chosen folder first: when it is the one Zoom writes to, the
        // default below is the empty leftover, not the live folder.
        let candidates = [customFolder, zoomLocalTranscriptDefaultFolder(homeDir: homeDir)]
            .compactMap { $0 }
        var roots: [String] = []
        var seen: Set<String> = []
        for candidate in candidates where isReadableZoomTranscriptFolder(candidate) {
            // A custom folder that resolves to the default — a symlink, or the
            // same path spelled differently — must not be watched twice.
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted else { continue }
            roots.append(candidate)
        }
        return roots
    }

    /// FSEvents setup itself must not become an implicit permission request,
    /// so a folder is only watched once it is there and readable.
    nonisolated static func isReadableZoomTranscriptFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: path)
    }

    /// Re-aim the watcher after the folder preference changes, so a newly
    /// chosen folder is read now rather than at the five-minute backstop.
    @MainActor
    func zoomLocalTranscriptFolderDidChange() {
        let roots = Self.zoomLocalTranscriptRoots(homeDir: BookmarkAccessManager.realHomeDirectory)
        zoomLocalTranscriptFileWatcher?.setWatchedRoots(roots)
        // A folder the learner just pointed at holds transcripts Zoom wrote
        // before ForeverLM knew about it; an empty snapshot files those.
        zoomLocalTranscriptSnapshot = [:]
        Task.detached(priority: .utility) { [weak self] in
            await self?.syncZoomLocalTranscriptsIfChanged(force: true)
        }
    }

    /// `[path: modification date]` for every transcript and recording folder
    /// in the folder — the no-op gate: an FSEvents fire that changed neither
    /// never imports. A recording folder is dated by its newest write, so a
    /// conversion finishing inside it moves the snapshot.
    nonisolated static func zoomLocalTranscriptSnapshot(roots: [String]) -> [String: Date] {
        var snapshot: [String: Date] = [:]
        for file in zoomLocalTranscriptFiles(roots: roots) {
            snapshot[file.path] = file.modifiedAt
        }
        for folder in zoomLocalRecordingFolders(roots: roots) {
            snapshot[folder.path] = folder.modifiedAt
        }
        return snapshot
    }

    /// The transcripts in the folder's top level whose names Zoom wrote. The
    /// recording folders beside them (`2026-09-12 08.44.39 <topic>/`) hold the
    /// media, never the transcript, and are not descended into.
    nonisolated static func zoomLocalTranscriptFiles(roots: [String]) -> [ZoomLocalTranscriptFile] {
        var files: [ZoomLocalTranscriptFile] = []
        for root in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in entries where name.lowercased().hasSuffix(".txt") {
                guard let parsed = parseZoomLocalTranscriptFileName(name) else { continue }
                let path = (root as NSString).appendingPathComponent(name)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      (attributes[.type] as? FileAttributeType) == .typeRegular,
                      let modifiedAt = attributes[.modificationDate] as? Date else { continue }
                files.append(ZoomLocalTranscriptFile(
                    path: path,
                    topic: parsed.topic,
                    startedAt: parsed.startedAt,
                    modifiedAt: modifiedAt
                ))
            }
        }
        return files.sorted { $0.startedAt < $1.startedAt }
    }

    /// `"Alan <> Zara standup 2026-09-12 08:44(GMT-7:00).txt"` →
    /// the topic and the meeting's start in the offset the name carries.
    /// Anything else in the folder — a chat log, a hand-saved note — is nil.
    nonisolated static func parseZoomLocalTranscriptFileName(_ fileName: String) -> (topic: String, startedAt: Date)? {
        let pattern = #"^(.+?) (\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})\(GMT([+-])(\d{1,2}):(\d{2})\)\.txt$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)) else {
            return nil
        }
        func group(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: fileName) else { return "" }
            return String(fileName[range])
        }
        let topic = group(1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty,
              let year = Int(group(2)), let month = Int(group(3)), let day = Int(group(4)),
              let hour = Int(group(5)), let minute = Int(group(6)),
              let offsetHours = Int(group(8)), let offsetMinutes = Int(group(9)) else { return nil }
        let sign = group(7) == "-" ? -1 : 1
        let offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        guard let timeZone = TimeZone(secondsFromGMT: offsetSeconds) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let startedAt = calendar.date(from: components) else { return nil }
        return (topic, startedAt)
    }

    // MARK: - Recording folders

    /// One recording Zoom saved: the folder `2026-09-19 08.30.13 Alan __ Zara/`
    /// and what is in it.
    struct ZoomLocalRecordingFolder: Equatable, Sendable {
        let path: String
        /// The topic as Zoom wrote it into the folder name, with every
        /// character it will not put in a file name replaced by `_` — so the
        /// meeting "Alan <> Zara" is the folder "Alan __ Zara". The real
        /// title comes back from the series and the calendar; see
        /// `zoomLocalRecordingTopic(folderTopic:knownTitles:)`.
        let folderTopic: String
        let startedAt: Date
        /// The newest write in the folder, the folder itself included.
        let modifiedAt: Date
        /// The converted media `recording.conf` names, audio before video,
        /// when Zoom has converted the recording.
        let mediaPath: String?
        /// A raw `double_click_to_convert_*.zoom` file, when it has not.
        let unconvertedPath: String?
        /// When Zoom wrote the converted media: the moment it converted the
        /// recording, which it does as the call ends. Nil while unconverted.
        var mediaWrittenAt: Date? = nil
    }

    /// Zoom converts a recording as soon as its meeting ends and takes a
    /// minute or two over it. A folder still holding only raw `.zoom` files
    /// this long after its last write is one Zoom did not convert — the client
    /// was quit first, or the conversion was cancelled — and offering it
    /// earlier would offer to convert what Zoom is about to convert anyway.
    nonisolated static let zoomLocalRecordingConversionWait: TimeInterval = 15 * 60

    /// Recording folders the learner said to leave alone — a meeting that did
    /// not happen, a recording not worth transcribing. Paths on this Mac, so
    /// plain `UserDefaults` like the folder preference and never synced; a
    /// folder that is gone drops out on the next write.
    nonisolated static let zoomLocalRecordingIgnoredFoldersKey = "studio.zoomLocalRecordingIgnoredFolders"

    /// The 2026-09-19 per-launch request counter, retired with the background
    /// request itself; a pass clears it so old builds' state does not linger.
    nonisolated static let zoomLocalRecordingConversionRequestsKey = "studio.zoomLocalRecordingConversionRequests"

    nonisolated static func zoomLocalRecordingIgnoredFoldersFromDefaults() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: zoomLocalRecordingIgnoredFoldersKey) ?? [])
    }

    /// Write the ignore list, dropping folders that no longer exist so the
    /// record stays the size of the Zoom folder rather than of its history.
    nonisolated static func saveZoomLocalRecordingIgnoredFolders(_ folders: Set<String>) {
        let kept = folders.filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        if kept.isEmpty {
            UserDefaults.standard.removeObject(forKey: zoomLocalRecordingIgnoredFoldersKey)
        } else {
            UserDefaults.standard.set(kept, forKey: zoomLocalRecordingIgnoredFoldersKey)
        }
    }

    /// The recording folders only Zoom can convert: no converted media, a raw
    /// `.zoom` file, no caption file covering the meeting, and still for
    /// `zoomLocalRecordingConversionWait`, so Zoom's own post-meeting
    /// conversion is not what is being waited for. Newest first, since the
    /// one the learner just ended is the one they are looking for. The ignore
    /// list is applied by the caller, so Settings can show both.
    nonisolated static func zoomLocalRecordingsNeedingConversion(
        _ folders: [ZoomLocalRecordingFolder],
        captions: [ZoomLocalTranscriptFile],
        now: Date = Date()
    ) -> [ZoomLocalRecordingFolder] {
        let stillBefore = now.addingTimeInterval(-zoomLocalRecordingConversionWait)
        return folders
            .filter {
                $0.mediaPath == nil && $0.unconvertedPath != nil
                    && $0.modifiedAt <= stillBefore
                    && !zoomLocalRecordingIsCaptioned($0, captions: captions)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Transcription attempts per recording per launch. It bills a provider,
    /// so a recording that fails to transcribe — no managed session, a media
    /// file AVFoundation cannot read — is tried on the backstop a bounded
    /// number of times, then left as the session in error it is until the
    /// next launch or a hand-driven `transcribe_meeting_recording`.
    nonisolated static let zoomLocalRecordingTranscriptAttemptCap = 3

    /// A caption file and a recording folder are one meeting when their
    /// topics agree and their starts fall within this. Zoom stamps the folder
    /// when the recording starts and the caption file to the minute, so the
    /// two are seconds apart, never minutes.
    nonisolated static let zoomLocalRecordingCaptionTolerance: TimeInterval = 3 * 60

    /// A free Zoom account ends a call after forty minutes and the host starts
    /// a new one: two recording folders, minutes apart, of one meeting. The
    /// reconnect often runs under another topic — the host's personal room,
    /// "Alan Young's Zoom Meeting", where the first call was the
    /// scheduled "Alan <> Zara" — so it cannot find its series by name. A
    /// recording that begins within this after the previous recording's call
    /// ended (`ZoomLocalRecordingEnd`), on the same local day, continues it:
    /// it files into the first call's series, and the sitting rule
    /// (`MeetingSessionContinuation`) folds the two sessions into one as its
    /// transcript lands. Ten minutes covers Zoom's parting dialog and a fresh
    /// invitation; a call that begins later than that after the last one
    /// ended is its own meeting. The Sep-19 and Sep-21 standups reconnected
    /// 19 s and 49 s after their first call.
    nonisolated static let zoomLocalRecordingReconnectGap: TimeInterval = 10 * 60

    /// How far before the previous recording stopped a reconnect may begin
    /// and still follow it. One client records both, so the two never
    /// overlap in fact; a minute covers the clock and the media's rounded
    /// duration.
    nonisolated static let zoomLocalRecordingReconnectOverlap: TimeInterval = 60

    /// When a recording's call ended, as far as its files can say. The
    /// media's length says when the recording stopped, and the call ran at
    /// least that long; the converted media's write says when Zoom converted
    /// the recording, which it does as the call ends, so the call ended no
    /// later than that. The two agree, to the minutes converting takes, for
    /// a call recorded to its end. They part when the host stops recording
    /// and the call goes on: on 2026-09-30 the host stopped recording the
    /// standup at 08:40 while the call went on, the free account cut the
    /// call at 09:11, Zoom wrote the media at 09:11:55, and the reconnect in
    /// the host's personal room at 09:11:26 — 31 min after the media's end — was
    /// filed as a meeting of its own. A conversion Zoom did not do on the
    /// spot (the client quit first; converted by hand later that day)
    /// stretches the later bound to that conversion, and a same-day call in
    /// the host's room begun in between is taken for a reconnect; that is
    /// rarer than a recording stopped before its call.
    struct ZoomLocalRecordingEnd: Equatable, Sendable {
        /// The recording's start plus its media's length: when it stopped.
        let noEarlierThan: Date
        /// When Zoom wrote the converted media, or `noEarlierThan` when that
        /// is unknown or earlier (a copied folder, a clock set back).
        let noLaterThan: Date

        /// Nil for a length nobody measured: a recording of unknown length
        /// is continued by nothing, since inventing one would decide
        /// identity on a guess.
        init?(startedAt: Date, duration: TimeInterval?, mediaWrittenAt: Date?) {
            guard let duration, duration.isFinite, duration > 0 else { return nil }
            let stopped = startedAt.addingTimeInterval(duration)
            noEarlierThan = stopped
            noLaterThan = max(stopped, mediaWrittenAt ?? stopped)
        }
    }

    /// Whether a topic is the name Zoom gives a call in the host's personal
    /// meeting room — "<name>'s Zoom Meeting", "<name>'s Personal Meeting
    /// Room" — as opposed to a scheduled meeting's own title. Such a call is
    /// what a host starts when Zoom has just ended the scheduled one.
    nonisolated static func zoomLocalRecordingIsPersonalRoomTopic(_ topic: String) -> Bool {
        let lowered = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasSuffix("zoom meeting") || lowered.hasSuffix("personal meeting room")
    }

    /// Whether `next` could continue `previous` before its recording's length
    /// is known: it starts after `previous` on the same local day, and either
    /// carries the same topic or runs in a personal meeting room. The cheap
    /// half of `zoomLocalRecordingContinues`, so a media file is opened for
    /// its duration only where the answer could be yes.
    nonisolated static func zoomLocalRecordingMayContinue(
        _ next: ZoomLocalRecordingFolder,
        _ previous: ZoomLocalRecordingFolder,
        calendar: Calendar = .current
    ) -> Bool {
        guard next.startedAt > previous.startedAt,
              calendar.isDate(next.startedAt, inSameDayAs: previous.startedAt) else { return false }
        return next.folderTopic.caseInsensitiveCompare(previous.folderTopic) == .orderedSame
            || zoomLocalRecordingIsPersonalRoomTopic(next.folderTopic)
    }

    /// Whether `next` continues `previous`: `zoomLocalRecordingMayContinue`,
    /// and it begins no earlier than `zoomLocalRecordingReconnectOverlap`
    /// before the previous recording stopped and no later than
    /// `zoomLocalRecordingReconnectGap` after its call can last have ended
    /// (`ZoomLocalRecordingEnd`). A previous recording whose end nothing
    /// says — not converted, or its media gone — is continued by nothing.
    nonisolated static func zoomLocalRecordingContinues(
        _ next: ZoomLocalRecordingFolder,
        _ previous: ZoomLocalRecordingFolder,
        previousEnd: ZoomLocalRecordingEnd?,
        calendar: Calendar = .current
    ) -> Bool {
        guard zoomLocalRecordingMayContinue(next, previous, calendar: calendar), let previousEnd else { return false }
        return next.startedAt >= previousEnd.noEarlierThan.addingTimeInterval(-zoomLocalRecordingReconnectOverlap)
            && next.startedAt <= previousEnd.noLaterThan.addingTimeInterval(zoomLocalRecordingReconnectGap)
    }

    /// For every folder that continues the one recorded before it, the
    /// folder its chain began with — the call whose series and topic the
    /// reconnect files under. A third call that continues the second continues
    /// the first. `ends` is each recording's end by folder path; folders may
    /// arrive in any order. Pure.
    nonisolated static func zoomLocalRecordingHeads(
        _ folders: [ZoomLocalRecordingFolder],
        ends: [String: ZoomLocalRecordingEnd],
        calendar: Calendar = .current
    ) -> [String: ZoomLocalRecordingFolder] {
        let sorted = folders.sorted { $0.startedAt < $1.startedAt }
        var heads: [String: ZoomLocalRecordingFolder] = [:]
        for (index, folder) in sorted.enumerated().dropFirst() {
            let previous = sorted[index - 1]
            guard zoomLocalRecordingContinues(
                folder, previous, previousEnd: ends[previous.path], calendar: calendar
            ) else { continue }
            heads[folder.path] = heads[previous.path] ?? previous
        }
        return heads
    }

    /// The length of a converted recording, read from its media; nil when
    /// AVFoundation cannot say.
    nonisolated static func zoomLocalRecordingDuration(mediaPath: String) async -> TimeInterval? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: mediaPath))
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// `"2026-09-19 08.30.13 Alan __ Zara"` → the topic as written and the
    /// start in the Mac's own time zone, which is the one Zoom names folders
    /// in. Anything else in the folder is nil.
    nonisolated static func parseZoomLocalRecordingFolderName(
        _ name: String,
        timeZone: TimeZone = .current
    ) -> (topic: String, startedAt: Date)? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2}) (\d{2})\.(\d{2})\.(\d{2}) (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else {
            return nil
        }
        func group(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: name) else { return "" }
            return String(name[range])
        }
        let topic = group(7).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty,
              let year = Int(group(1)), let month = Int(group(2)), let day = Int(group(3)),
              let hour = Int(group(4)), let minute = Int(group(5)), let second = Int(group(6)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let startedAt = calendar.date(from: components) else { return nil }
        return (topic, startedAt)
    }

    /// A meeting title the way Zoom writes it into a file or folder name:
    /// every character a file name cannot carry becomes `_`.
    nonisolated static func zoomFileNameTopic(_ title: String) -> String {
        meetingTitleFileNameSpelling(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The media files a folder's `recording.conf` says are converted, audio
    /// before video, in the order Zoom lists them. The file reads
    /// `{"magic_number":"…","items":[{"process":100,"audio":"audio1.m4a",
    /// "video":"video1.mp4"}]}` once converted and holds no `items` before.
    nonisolated static func zoomConvertedMediaNames(inRecordingConf data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return [] }
        var names: [String] = []
        for item in items {
            let progress = (item["process"] as? NSNumber)?.intValue ?? 0
            guard progress >= 100 else { continue }
            for key in ["audio", "video"] {
                if let name = item[key] as? String, !name.isEmpty {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// The recording folders in the roots' top level, oldest first. The media
    /// a folder offers is the first converted file that exists on disk; a
    /// folder with none but a raw `.zoom` file is one Zoom has yet to convert.
    nonisolated static func zoomLocalRecordingFolders(roots: [String]) -> [ZoomLocalRecordingFolder] {
        let fileManager = FileManager.default
        var folders: [ZoomLocalRecordingFolder] = []
        for root in roots {
            let entries = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
            for name in entries {
                guard let parsed = parseZoomLocalRecordingFolderName(name) else { continue }
                let path = (root as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let children = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
                var modifiedAt = ((try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
                var writtenAt: [String: Date] = [:]
                for child in children {
                    let childPath = (path as NSString).appendingPathComponent(child)
                    guard let date = (try? fileManager.attributesOfItem(atPath: childPath))?[.modificationDate] as? Date else { continue }
                    writtenAt[childPath] = date
                    if date > modifiedAt { modifiedAt = date }
                }
                var mediaPath: String?
                if let conf = fileManager.contents(atPath: (path as NSString).appendingPathComponent("recording.conf")) {
                    mediaPath = zoomConvertedMediaNames(inRecordingConf: conf)
                        .map { (path as NSString).appendingPathComponent($0) }
                        .first { fileManager.fileExists(atPath: $0) }
                }
                let unconvertedPath = mediaPath == nil
                    ? children.filter { $0.lowercased().hasSuffix(".zoom") }.sorted().first
                        .map { (path as NSString).appendingPathComponent($0) }
                    : nil
                folders.append(ZoomLocalRecordingFolder(
                    path: path,
                    folderTopic: parsed.topic,
                    startedAt: parsed.startedAt,
                    modifiedAt: modifiedAt,
                    mediaPath: mediaPath,
                    unconvertedPath: unconvertedPath,
                    mediaWrittenAt: mediaPath.flatMap { writtenAt[$0] }
                ))
            }
        }
        return folders.sorted { $0.startedAt < $1.startedAt }
    }

    /// The meeting's real title, recovered from the titles the folder name
    /// could have been written from — the series in the library and the day's
    /// calendar events, in that order: the first whose file-name form is the
    /// folder's topic and that is not itself spelled like a file name. A
    /// series made from a folder before its real title was known — the
    /// "Alan __ Zara" group of 2026-09-23, since merged into the standup —
    /// matches every folder of that meeting and recovers nothing, and it
    /// outranked the calendar's "Alan <> Zara" for every standup after it.
    /// Such a title is used only when nothing better matches, and the
    /// folder's own spelling when nothing matches at all.
    nonisolated static func zoomLocalRecordingTopic(folderTopic: String, knownTitles: [String]) -> String {
        var sameSpelling: String?
        for title in knownTitles {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = zoomFileNameTopic(trimmed)
            guard !trimmed.isEmpty,
                  fileName.caseInsensitiveCompare(folderTopic) == .orderedSame else { continue }
            if fileName != trimmed { return trimmed }
            sameSpelling = sameSpelling ?? trimmed
        }
        return sameSpelling ?? folderTopic
    }

    /// The name a Zoom session is stored under in the series titled
    /// `seriesTitle`: the series' own title when the topic is that series cut
    /// short or respelled — "Alan <> Zara" or Zoom's file-name "Alan __
    /// Zara" under "Alan <> Zara standup" — so every session of a series is
    /// titled `<series> - <date time>`, whichever way its file spelled the
    /// meeting. A topic that says more than the series, or something else,
    /// keeps its own name. Only the title follows the series: the session's
    /// URL keeps the key its file gives it, so a session filed before this
    /// is never filed a second time.
    nonisolated static func zoomSessionName(topic: String, seriesTitle: String?) -> String {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let series = seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !series.isEmpty,
              series.count >= trimmedTopic.count,
              isSeriesVariant(trimmedTopic, of: series) else { return trimmedTopic }
        return series
    }

    /// Whether a caption file describes the same meeting as the folder, in
    /// which case the caption is the transcript and the recording is not
    /// transcribed again.
    nonisolated static func zoomLocalRecordingIsCaptioned(
        _ folder: ZoomLocalRecordingFolder,
        captions: [ZoomLocalTranscriptFile]
    ) -> Bool {
        captions.contains { caption in
            zoomFileNameTopic(caption.topic).caseInsensitiveCompare(folder.folderTopic) == .orderedSame
                && abs(caption.startedAt.timeIntervalSince(folder.startedAt)) <= zoomLocalRecordingCaptionTolerance
        }
    }

    /// The series a topic belongs to: the group titled exactly that, or else
    /// the one group whose title begins with it as a word. The second rule is
    /// for a series renamed in the calendar — "Alan <> Zara standup" became
    /// "Alan <> Zara" — whose sessions must keep filing into the group the
    /// older name made, as the sessions filed by hand did. Two groups that
    /// both begin with the topic settle nothing, and nil says so. Both sides
    /// are compared in their file-name form, so a folder's "Alan __ Zara"
    /// whose real title could not be recovered still finds "Alan <> Zara
    /// standup" instead of opening a folder of its own.
    nonisolated static func zoomLocalRecordingSeriesID(topic: String, groups: [String: MeetingMetadata]) -> String? {
        let wanted = zoomFileNameTopic(topic).lowercased()
        guard !wanted.isEmpty else { return nil }
        var exact: [String] = []
        var prefixed: [String] = []
        for (id, metadata) in groups where metadata.mergedIntoGroupID == nil {
            guard let title = metadata.title.map({ zoomFileNameTopic($0).lowercased() }),
                  !title.isEmpty else { continue }
            if title == wanted {
                exact.append(id)
            } else if title.hasPrefix(wanted + " ") {
                prefixed.append(id)
            }
        }
        if let id = exact.sorted().first { return id }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    nonisolated static func zoomMediaMIMEType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Transcript text

    /// Zoom's caption file is one cue per block — a `HH:MM:SS --> HH:MM:SS`
    /// line, then `Speaker: text` — which reads badly and doubles the length.
    /// Folded to `[HH:MM:SS] Speaker: text`, one line per cue, in file order.
    /// Nil when the file holds no cue at all.
    nonisolated static func formatZoomCaptionTranscript(_ raw: String) -> String? {
        var lines: [String] = []
        var pendingStart: String?
        for rawLine in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let arrow = line.range(of: " --> ") {
                let start = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let looksLikeTime = start.count >= 7 && start.allSatisfy { $0.isNumber || $0 == ":" || $0 == "." }
                if looksLikeTime {
                    pendingStart = String(start.prefix(while: { $0 != "." }))
                    continue
                }
            }
            if let start = pendingStart {
                lines.append("[\(start)] \(line)")
                pendingStart = nil
            } else {
                lines.append(line)
            }
        }
        guard lines.contains(where: { $0.hasPrefix("[") }) else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Who spoke, read off a transcript's speaker labels: every distinct
    /// `Name:` that opens a timed line, in order of first appearance. Zoom's
    /// saved captions carry the name each cue was attributed to, so a
    /// transcript folded by `formatZoomCaptionTranscript` reads
    /// `[08:45:52] Zara Holt: How's it going?`. Empty for a transcript with
    /// no labels — one ForeverLM transcribed itself says who was there in no
    /// way at all, and nothing is guessed from it.
    nonisolated static func zoomCaptionSpeakers(_ transcript: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"^\[\d{1,2}:\d{2}(?::\d{2})?\]\s+([^:\n]{1,80}?):\s"#) else { return [] }
        var names: [String] = []
        var seen: Set<String> = []
        for rawLine in transcript.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line) else { continue }
            let name = line[nameRange].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// The one line a session shows for who was there, from the best record
    /// that speaks for it: who spoke, when the transcript says; else who the
    /// calendar invited, when it names every guest by name; else the line
    /// its series' sessions share (`zoomSeriesParticipantLine`); else the
    /// invitation as the calendar spells it, addresses and all; else nothing.
    ///
    /// The series outranks an invitation that knows someone only by address
    /// because the standup's Google invitation lists "zara.holt@example.org"
    /// and not its host, and a standup moved off its calendar slot has no
    /// invitation at all — so four of fifteen rows in one folder read an
    /// address or no one beside eleven that read "Alan Young, Zara
    /// Holt" (product owner, 2026-09-28: "can you please make sure these zoom
    /// meetings show up consistently?", after the same ask on 2026-09-22).
    nonisolated static func zoomSessionParticipantLine(
        speakers: [String],
        invited: [String],
        series: String? = nil
    ) -> String? {
        if let line = MeetingCalendarEvent.participantLine(speakers) { return line }
        let guests = invited
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !guests.isEmpty, !guests.contains(where: isParticipantAddress) {
            return MeetingCalendarEvent.participantLine(guests)
        }
        if let series = series?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            return series
        }
        return MeetingCalendarEvent.participantLine(guests)
    }

    /// The line most of a series' sessions give for who was there, when
    /// more than half of those that name anyone by name agree and at least
    /// two do. A series where the same people meet every time has one; a
    /// group whose room changes week to week has none, and its sessions
    /// keep only what their own records say. A line with an address in it
    /// is the calendar's spelling, not a name, and does not count.
    nonisolated static func zoomSeriesParticipantLine(_ lines: [String?]) -> String? {
        let named = lines
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in !line.split(separator: ",").contains { isParticipantAddress(String($0)) } }
        guard named.count >= 2 else { return nil }
        var counts: [String: (line: String, count: Int)] = [:]
        for line in named {
            let key = line.lowercased()
            counts[key] = (counts[key]?.line ?? line, (counts[key]?.count ?? 0) + 1)
        }
        guard let best = counts.values.max(by: { $0.count < $1.count }),
              best.count >= 2, best.count * 2 > named.count else { return nil }
        return best.line
    }

    /// The shared line of every series in `articles`, by the series' group ID.
    nonisolated static func zoomSeriesParticipantLines(_ articles: [StudioArticle]) -> [String: String] {
        var lines: [String: [String?]] = [:]
        for article in articles where article.sourceType == .meeting && article.status == .active {
            guard let group = article.parentGroup, !group.isEmpty else { continue }
            lines[group, default: []].append(article.author)
        }
        return lines.compactMapValues(zoomSeriesParticipantLine)
    }

    /// Whether one entry of a people line is an address rather than a name.
    nonisolated static func isParticipantAddress(_ entry: String) -> Bool {
        entry.contains("@")
    }

    /// The stable URL a Zoom local transcript files under: the same shape
    /// `import_meeting_transcript_files` gives a session, so a transcript
    /// filed by hand through MCP with this key and the one the watcher finds
    /// later are one session, never two.
    nonisolated static func zoomLocalTranscriptSessionURL(groupID: String, sessionKey: String) -> String {
        "meeting://\(groupID)/\(percentEncodedMeetingPathComponent(sessionKey))"
    }

    // MARK: - Auto sync

    /// Arm the watcher after the persisted library is on screen, like the
    /// reading-list and podcast watchers.
    func startZoomLocalTranscriptAutoSync() {
        guard zoomLocalTranscriptAutoSyncTask == nil else { return }
        zoomLocalTranscriptAutoSyncTask = Task { [weak self] in
            await self?.runZoomLocalTranscriptAutoSync()
        }
    }

    nonisolated func runZoomLocalTranscriptAutoSync() async {
        let homeDir = BookmarkAccessManager.realHomeDirectory
        let watcher = LocalSourceFileWatcher(content: .zoomLocalTranscripts) { [weak self] in
            guard let self else { return }
            Task.detached(priority: .utility) {
                await self.syncZoomLocalTranscriptsIfChanged()
            }
        }
        defer { watcher.cancel() }

        await MainActor.run {
            // Start from an empty snapshot so transcripts Zoom wrote while
            // ForeverLM was closed are filed by the first pass.
            self.zoomLocalTranscriptSnapshot = [:]
            self.zoomLocalTranscriptFileWatcher = watcher
        }
        watcher.setWatchedRoots(Self.zoomLocalTranscriptRoots(homeDir: homeDir))
        await syncZoomLocalTranscriptsIfChanged(force: true)

        // Backstop behind FSEvents, and the pass that files a transcript whose
        // settle window had not elapsed when its last write fired the watcher.
        // The interval is shorter than the other watchers' because a meeting
        // that just ended is what the learner is about to look for.
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            watcher.setWatchedRoots(Self.zoomLocalTranscriptRoots(homeDir: homeDir))
            await syncZoomLocalTranscriptsIfChanged()
        }
    }

    nonisolated func syncZoomLocalTranscriptsIfChanged(force: Bool = false) async {
        let started = await MainActor.run { () -> Bool in
            if self.zoomLocalTranscriptAutoSyncInFlight {
                self.zoomLocalTranscriptAutoSyncNeedsAnotherPass = true
                self.zoomLocalTranscriptAutoSyncNeedsForcedPass = self.zoomLocalTranscriptAutoSyncNeedsForcedPass || force
                return false
            }
            self.zoomLocalTranscriptAutoSyncInFlight = true
            return true
        }
        guard started else { return }

        var forceNextPass = force
        while true {
            await performZoomLocalTranscriptSyncIfChanged(force: forceNextPass)
            let nextPass = await MainActor.run { () -> (shouldContinue: Bool, force: Bool) in
                if self.zoomLocalTranscriptAutoSyncNeedsAnotherPass {
                    let shouldForce = self.zoomLocalTranscriptAutoSyncNeedsForcedPass
                    self.zoomLocalTranscriptAutoSyncNeedsAnotherPass = false
                    self.zoomLocalTranscriptAutoSyncNeedsForcedPass = false
                    return (true, shouldForce)
                }
                self.zoomLocalTranscriptAutoSyncInFlight = false
                return (false, false)
            }
            guard nextPass.shouldContinue else { return }
            forceNextPass = nextPass.force
        }
    }

    struct ZoomLocalTranscriptSyncBase: Sendable {
        let storage: StorageService
        let activeTeamID: String?
    }

    nonisolated func performZoomLocalTranscriptSyncIfChanged(force: Bool) async {
        let homeDir = BookmarkAccessManager.realHomeDirectory
        let roots = Self.zoomLocalTranscriptRoots(homeDir: homeDir)
        guard !roots.isEmpty else { return }
        let files = Self.zoomLocalTranscriptFiles(roots: roots)
        let folders = Self.zoomLocalRecordingFolders(roots: roots)
        var fileSnapshot: [String: Date] = [:]
        for file in files { fileSnapshot[file.path] = file.modifiedAt }
        for folder in folders { fileSnapshot[folder.path] = folder.modifiedAt }

        // What only Zoom can convert is put in front of the learner on every
        // pass, gate or no gate: the fifteen-minute wait elapses with nothing
        // on disk changing, and the backstop is what brings the row up then.
        let needingConversion = Self.zoomLocalRecordingsNeedingConversion(folders, captions: files)
        let ignored = Self.zoomLocalRecordingIgnoredFoldersFromDefaults()
        if UserDefaults.standard.object(forKey: Self.zoomLocalRecordingConversionRequestsKey) != nil {
            UserDefaults.standard.removeObject(forKey: Self.zoomLocalRecordingConversionRequestsKey)
        }
        await MainActor.run {
            let knownTitles = self.meetingMetadata.values.compactMap(\.title)
            let waiting = needingConversion.map {
                ZoomLocalRecordingAwaitingConversion(
                    folder: $0,
                    title: Self.zoomLocalRecordingTopic(folderTopic: $0.folderTopic, knownTitles: knownTitles)
                )
            }
            if waiting != self.zoomLocalUnconvertedRecordings {
                self.zoomLocalUnconvertedRecordings = waiting
            }
            if ignored != self.zoomLocalRecordingIgnoredFolders {
                self.zoomLocalRecordingIgnoredFolders = ignored
            }
        }
        await convertZoomLocalRecordingAutomatically(waiting: needingConversion, ignored: ignored)

        let currentSnapshot = fileSnapshot
        let base = await MainActor.run { () -> ZoomLocalTranscriptSyncBase? in
            // A recording whose transcription failed is retried by the
            // backstop even though nothing in the folder moved.
            guard !self.isLoadingQueue,
                  force || currentSnapshot != self.zoomLocalTranscriptSnapshot
                      || !self.zoomLocalRecordingRetryPending.isEmpty else {
                return nil
            }
            return ZoomLocalTranscriptSyncBase(
                storage: self.storage,
                activeTeamID: self.activeTeamID
            )
        }
        guard let base else { return }

        // Only transcripts Zoom has finished writing, and only recording
        // folders it has stopped writing into. A file still moving is left
        // for the next fire or the backstop, and its entry stays out of the
        // snapshot so that pass is not gated away.
        let settledBefore = Date().addingTimeInterval(-Self.zoomLocalTranscriptSettleInterval)
        let settled = files.filter { $0.modifiedAt <= settledBefore }
        let settledFolders = folders.filter { $0.modifiedAt <= settledBefore }
        var recordedSnapshot = fileSnapshot
        for file in files where file.modifiedAt > settledBefore {
            recordedSnapshot.removeValue(forKey: file.path)
        }
        for folder in folders where folder.modifiedAt > settledBefore {
            recordedSnapshot.removeValue(forKey: folder.path)
        }
        let settledSnapshot = recordedSnapshot
        await MainActor.run { self.zoomLocalTranscriptSnapshot = settledSnapshot }

        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ZoomTranscriptWatcher")
        let removedGroupTitles = Self.loadRemovedMeetingGroupTitles()
        let seriesLines = await MainActor.run { Self.zoomSeriesParticipantLines(self.articles) }
        let insertedIDs = await Self.importZoomLocalTranscripts(
            settled,
            storage: base.storage,
            removedGroupTitles: removedGroupTitles,
            seriesParticipantLines: seriesLines
        )
        if !insertedIDs.isEmpty {
            log.info("Zoom local transcripts filed \(insertedIDs.count) session(s)")
            await reloadSourcesAfterZoomLocalFiling(base: base, log: log)
        }

        // The caption files first, so a recording whose captions were saved
        // is seen as captioned rather than transcribed a second time.
        await importZoomLocalRecordings(
            settledFolders,
            captions: files,
            base: base,
            removedGroupTitles: removedGroupTitles,
            log: log
        )

        await backfillZoomSessionParticipants(base: base, log: log)
    }

    // MARK: - Who was there, for sessions filed before it was written

    /// Write who was there on each Zoom session that was filed without it, or
    /// with only the calendar's addresses: sessions the watcher filed before
    /// it wrote a presenter, and sessions whose calendar could not be read,
    /// or spelled a guest by address, the moment they were filed. The word
    /// comes from where filing reads it — the stored transcript's speaker
    /// labels, else the invitation behind the block the session is attached
    /// to, else the line its series shares — and a session none can speak
    /// for is left as it is and not asked again this launch, so a folder of
    /// standups reads one way.
    nonisolated func backfillZoomSessionParticipants(base: ZoomLocalTranscriptSyncBase, log: Logger) async {
        let (candidates, seriesLines) = await MainActor.run { () -> ([StudioArticle], [String: String]) in
            let candidates = self.articles.filter { article in
                guard article.sourceType == .meeting, article.discoveryOrigin == .zoom, article.state == .ready,
                      !self.zoomSessionParticipantBackfillTried.contains(article.id) else { return false }
                let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return author.isEmpty
                    || author.split(separator: ",").allSatisfy { Self.isParticipantAddress(String($0)) }
            }
            return (candidates, candidates.isEmpty ? [:] : Self.zoomSeriesParticipantLines(self.articles))
        }
        guard !candidates.isEmpty else { return }
        var written = 0
        for article in candidates {
            await MainActor.run { _ = self.zoomSessionParticipantBackfillTried.insert(article.id) }
            var content = article.content
            if content == nil { content = await base.storage.loadSourceContent(article.id) }
            let transcript = MeetingContent.text(for: .transcript, in: content) ?? ""
            let speakers = Self.zoomCaptionSpeakers(transcript)
            let current = article.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var invited: [String] = []
            // A session that already carries the invitation's addresses would
            // only read them again; the series is what can name them.
            if speakers.isEmpty, current.isEmpty, let startedAt = MeetingCalendarEvent.knownStart(of: article) {
                // The Zoom watcher keeps the meeting's topic in `domain`.
                let topic = article.domain.trimmingCharacters(in: .whitespacesAndNewlines)
                invited = await MeetingCalendarEvent.invitedNames(startedAt: startedAt, title: topic.isEmpty ? article.title : topic)
            }
            guard let line = Self.zoomSessionParticipantLine(
                speakers: speakers, invited: invited, series: article.parentGroup.flatMap { seriesLines[$0] }
            ), line != current else { continue }
            await MainActor.run { [line] in
                Task { @MainActor in await self.updateArticleAuthor(id: article.id, author: line) }
            }
            written += 1
        }
        if written > 0 {
            log.info("Zoom sessions given who was there: \(written)")
        }
    }

    /// Put what a pass filed on screen. Reads the articles as they are now,
    /// not as they were when the pass began: a transcription runs for
    /// minutes, and content the learner opened meanwhile must survive.
    nonisolated func reloadSourcesAfterZoomLocalFiling(base: ZoomLocalTranscriptSyncBase, log: Logger) async {
        let reloaded: [StudioArticle]
        let metadata: [String: MeetingMetadata]
        do {
            reloaded = try await base.storage.loadLibrarySources(teamID: base.activeTeamID).sources
            metadata = try await base.storage.loadMeetingMetadata()
        } catch {
            log.error("Failed to reload sources after filing Zoom transcripts: \(error.localizedDescription)")
            return
        }
        let previous = await MainActor.run { self.articles }
        let merged = await Task.detached(priority: .userInitiated) {
            Self.preservingLoadedContent(in: reloaded, preservingFrom: previous)
        }.value
        await MainActor.run {
            self.articles = merged
            self.meetingMetadata = metadata
            self.syncCloudKitInBackground()
        }
    }

    // MARK: - Recordings without captions

    /// File each settled recording folder that no caption file covers.
    ///
    /// A converted recording becomes a session of the series its topic names
    /// — the topic recovered from the library's series and the day's calendar
    /// events, since the folder name is Zoom's file-safe spelling of it — with
    /// the recording as its artifact, and is then transcribed. A meeting that
    /// ran over into a second scheduled slot is two folders, and each files
    /// as its own session, keyed by its own start (product owner, 2026-09-19: "i
    /// might also run over time with the meetings so then schedule a second
    /// one; it should always auto-add those transcripts"). A folder that
    /// begins within minutes of the previous recording's end continues it
    /// (`zoomLocalRecordingHeads`): it takes the first call's topic and
    /// series, whatever its own folder is named, so that the sitting rule
    /// folds the two sessions into one when its transcript lands. Before
    /// this, the 2026-09-21 standup's second call — Zoom's forty-minute cut,
    /// reconnected 49 s later in the host's personal room — was named
    /// "Alan Young's Zoom Meeting", a series the learner had removed, and
    /// was dropped without a word; the standup's transcript ended
    /// mid-sentence (the product owner: "it didn't add together both transcripts from
    /// the two meetings").
    ///
    /// Transcription here is not behind the Google Drive card's "transcribe
    /// when Google did not" switch: that switch guards against paying to
    /// re-derive a transcript Gemini already wrote, and a local Zoom recording
    /// without captions has no transcript anywhere else.
    ///
    /// A recording Zoom has not converted cannot be read here; it is listed
    /// for the learner (`zoomLocalRecordingsAwaitingConversion`), and the
    /// converted files arriving in the folder after their **Convert in Zoom**
    /// bring the pass back.
    ///
    /// A converted recording with no speech in it is not filed at all
    /// (`RecordingSpeechLevel`): a call opened and closed without a word, or
    /// one Zoom restarted before anyone spoke. The speech model answered such
    /// recordings with a Russian letter about a UN trade programme and a
    /// Spanish sign-off, which were filed as two English standups' transcripts,
    /// and fed action-item extraction.
    nonisolated func importZoomLocalRecordings(
        _ folders: [ZoomLocalRecordingFolder],
        captions: [ZoomLocalTranscriptFile],
        base: ZoomLocalTranscriptSyncBase,
        removedGroupTitles: [String],
        log: Logger
    ) async {
        let storage = base.storage
        let sorted = folders.sorted { $0.startedAt < $1.startedAt }

        // The length of each recording a later one could continue, read once
        // per folder and kept for the launch: the media does not change.
        var durations = await MainActor.run { self.zoomLocalRecordingDurations }
        for (index, folder) in sorted.enumerated().dropFirst() {
            let previous = sorted[index - 1]
            guard durations[previous.path] == nil,
                  let previousMedia = previous.mediaPath,
                  Self.zoomLocalRecordingMayContinue(folder, previous),
                  let duration = await Self.zoomLocalRecordingDuration(mediaPath: previousMedia) else { continue }
            durations[previous.path] = duration
        }
        let knownDurations = durations
        await MainActor.run { self.zoomLocalRecordingDurations = knownDurations }
        var ends: [String: ZoomLocalRecordingEnd] = [:]
        for folder in sorted {
            guard let end = ZoomLocalRecordingEnd(
                startedAt: folder.startedAt, duration: knownDurations[folder.path], mediaWrittenAt: folder.mediaWrittenAt
            ) else { continue }
            ends[folder.path] = end
        }
        let heads = Self.zoomLocalRecordingHeads(sorted, ends: ends)
        let seriesLines = await MainActor.run { Self.zoomSeriesParticipantLines(self.articles) }
        let withoutSpeech = await MainActor.run { self.zoomLocalRecordingsWithoutSpeech }

        for folder in sorted {
            if Self.zoomLocalRecordingIsCaptioned(folder, captions: captions) { continue }
            guard let mediaPath = folder.mediaPath, !withoutSpeech.contains(folder.path) else { continue }
            let attempts = await MainActor.run { self.zoomLocalRecordingTranscriptAttempts[folder.path] ?? 0 }
            guard attempts < Self.zoomLocalRecordingTranscriptAttemptCap else { continue }

            do {
                // A reconnect is named after the call it continues; its own
                // folder says only that the host's room was used.
                let named = heads[folder.path] ?? folder
                let groups = try await storage.loadMeetingMetadata()
                let date = DayPlan.dateString(for: named.startedAt)
                let calendarTitles = await MeetingCalendarEvent.meetingTitles(on: date)
                let topic = Self.zoomLocalRecordingTopic(
                    folderTopic: named.folderTopic,
                    knownTitles: groups.values.compactMap(\.title) + calendarTitles
                )
                if Self.removedMeetingGroupTitles(removedGroupTitles, include: topic) {
                    log.info("Zoom recording \(folder.path, privacy: .public) is of the removed series '\(topic, privacy: .public)'; not filed")
                    continue
                }

                let existingGroupID: String?
                if let series = Self.zoomLocalRecordingSeriesID(topic: topic, groups: groups),
                   let resolved = try await storage.resolvedMeetingGroupID(matching: series) {
                    existingGroupID = resolved
                } else {
                    existingGroupID = try await storage.resolvedMeetingGroupID(matching: topic)
                }
                // The session's key carries the title, and the title this
                // pass recovers can differ from the one another pass or Mac
                // recovered ("Alan <> Zara" against "Alan __ Zara"), so
                // the recording folder itself is what says it is filed —
                // under any series. A session moved to another series by
                // hand, or folded into a sitting there, keeps its recording,
                // and its rows can still name the series it was filed under:
                // on 2026-09-30 the standup's personal-room reconnect was
                // moved into the standup series and folded in, and a look at
                // that series' own rows alone would have filed the recording
                // again and paid to transcribe it a second time.
                let folderName = (folder.path as NSString).lastPathComponent
                let filed = try await storage.loadMeetingArtifacts()
                if filed.contains(where: { artifact in
                    guard artifact.kind == .recording, let path = artifact.localFilePath else { return false }
                    return ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == folderName
                }) { continue }
                // A call nobody spoke in is not a meeting: it is not filed,
                // its planner block is not marked done, and nothing is sent to
                // be transcribed, since a speech model makes something up for
                // silence (`RecordingSpeechLevel`). Measured before a series
                // is made for it too, so a call that never happened leaves no
                // empty folder behind.
                if let level = await RecordingSpeechLevel.measure(mediaURL: URL(fileURLWithPath: mediaPath)),
                   !level.hasSpeech {
                    await MainActor.run { _ = self.zoomLocalRecordingsWithoutSpeech.insert(folder.path) }
                    log.info("Zoom recording \(folder.path, privacy: .public) has no speech in it (\(RecordingSpeechLevel.summary(level), privacy: .public)); not filed")
                    continue
                }
                let groupID: String
                if let existingGroupID {
                    groupID = existingGroupID
                } else {
                    try await storage.saveMeetingGroup(name: topic, metadata: MeetingMetadata(title: topic))
                    groupID = topic
                }
                let sessionKey = Self.readAISessionKey(title: topic, date: folder.startedAt, includeTime: true)
                let url = Self.zoomLocalTranscriptSessionURL(groupID: groupID, sessionKey: sessionKey)
                // The key keeps the topic the folder gave; the title is the
                // series', so the folder reads one way whatever Zoom named
                // the file.
                let name = Self.zoomSessionName(topic: topic, seriesTitle: groups[groupID]?.title)
                let sessionTitle = Self.readAISessionKey(title: name, date: folder.startedAt, includeTime: true)

                var article: StudioArticle
                if let existing = try await storage.sourceExistsByURL(url) {
                    // Filed already — by an earlier pass, or by hand over MCP
                    // under the same key. Only a session still without its
                    // transcript is taken further; a removed one is left be.
                    guard existing.status == .active else { continue }
                    let artifacts = try await storage.loadMeetingArtifacts(sourceID: existing.id)
                    if artifacts.contains(where: { $0.kind == .transcript }) { continue }
                    guard var stored = try await storage.loadSourceWithoutContent(existing.id) else { continue }
                    stored.content = await storage.loadSourceContent(existing.id)
                    if MeetingContent.contains(section: .transcript, in: stored.content) { continue }
                    article = stored
                } else {
                    let fileName = (mediaPath as NSString).lastPathComponent
                    article = StudioArticle(
                        url: url,
                        title: sessionTitle,
                        sourceType: .meeting,
                        discoveryOrigin: .zoom,
                        parentGroup: groupID
                    )
                    article.domain = topic
                    article.dateAdded = folder.startedAt
                    article.localFilePath = mediaPath
                    article.content = MeetingContent.inserting(
                        section: .recording, text: fileName, into: nil, title: sessionTitle
                    )
                    article.wordCount = article.content?.split(separator: " ").count
                    article.state = .fetching
                    guard try await storage.insertSourceIfNew(&article) else { continue }
                    try await storage.saveMeetingArtifact(MeetingArtifact(
                        id: SourceIdentity.stableID(for: "\(article.id):zoom-local:recording"),
                        sourceId: article.id,
                        groupId: groupID,
                        kind: .recording,
                        title: "\(name) Recording",
                        url: nil,
                        localFilePath: mediaPath,
                        mimeType: Self.zoomMediaMIMEType(mediaPath),
                        modifiedAt: folder.startedAt,
                        sortIndex: MeetingArtifactKind.recording.sortRank
                    ))
                    // The meeting is on the Mac's Calendar, drawn there before
                    // it happened; this is its recording. An on-device
                    // transcript names no speakers, so the invitation, or else
                    // the people the series always has, is the session's word
                    // on who was there, written now rather than after a
                    // transcription that can fail.
                    let invited = await MeetingCalendarEvent.invitedNames(startedAt: folder.startedAt, title: topic)
                    if let line = Self.zoomSessionParticipantLine(
                        speakers: [], invited: invited, series: seriesLines[groupID]
                    ) {
                        article.author = line
                        try await storage.saveSource(article, syncImmediately: true)
                    }
                    if let head = heads[folder.path] {
                        log.info("Zoom recording \(folder.path, privacy: .public) continues \(head.path, privacy: .public); filed as a session of '\(topic, privacy: .public)'; transcribing")
                    } else {
                        log.info("Zoom recording \(folder.path, privacy: .public) filed as a session; transcribing")
                    }
                    await reloadSourcesAfterZoomLocalFiling(base: base, log: log)
                }

                // Transcription stopped under Running in the background: the
                // recording waits, filed and saying so, and the first pass
                // after the learner resumes it transcribes it. No attempt is
                // spent and no audio is read while it waits.
                if AIInFlightCalls.shared.isStopped(MeetingTranscriptionService.meetingTask) {
                    let stop = AIStepStoppedError(
                        step: AIInFlightCalls.stepName(MeetingTranscriptionService.meetingTask),
                        staysStopped: true
                    )
                    if article.errorMessage != stop.localizedDescription {
                        article.state = .error
                        article.errorMessage = stop.localizedDescription
                        try? await storage.saveSource(article)
                    }
                    await MainActor.run { _ = self.zoomLocalRecordingRetryPending.insert(folder.path) }
                    await reloadSourcesAfterZoomLocalFiling(base: base, log: log)
                    continue
                }
                await MainActor.run { self.zoomLocalRecordingTranscriptAttempts[folder.path] = attempts + 1 }
                do {
                    let transcript = try await MeetingTranscriptionService.shared.transcribe(
                        localMediaURL: URL(fileURLWithPath: mediaPath)
                    )
                    article.content = MeetingContent.inserting(
                        section: .transcript, text: transcript, into: article.content, title: article.title
                    )
                    article.wordCount = article.content?.split(separator: " ").count
                    article.state = .ready
                    article.errorMessage = nil
                    try await storage.saveSource(article, syncImmediately: true)
                    try await storage.saveMeetingArtifact(MeetingArtifact(
                        id: SourceIdentity.stableID(for: "\(article.id):zoom-local:transcript"),
                        sourceId: article.id,
                        groupId: groupID,
                        kind: .transcript,
                        title: "\(name) Transcript",
                        url: nil,
                        localFilePath: nil,
                        mimeType: "text/plain",
                        modifiedAt: Date(),
                        sortIndex: MeetingArtifactKind.transcript.sortRank
                    ))
                    MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: article.id)
                    await MainActor.run {
                        self.zoomLocalRecordingTranscriptAttempts.removeValue(forKey: folder.path)
                        self.zoomLocalRecordingRetryPending.remove(folder.path)
                    }
                    log.info("Zoom recording \(folder.path, privacy: .public) transcribed")
                } catch where AITransientErrorClassifier.isCancellation(error) {
                    // Stopped, not failed: the attempt is given back, and the
                    // recording waits for the next pass.
                    article.state = .error
                    article.errorMessage = error.localizedDescription
                    try? await storage.saveSource(article)
                    await MainActor.run {
                        self.zoomLocalRecordingTranscriptAttempts[folder.path] = attempts
                        _ = self.zoomLocalRecordingRetryPending.insert(folder.path)
                    }
                    log.info("Transcribing Zoom recording \(folder.path, privacy: .public) was stopped")
                } catch {
                    article.state = .error
                    article.errorMessage = "Transcribing the Zoom recording failed: \(error.localizedDescription)"
                    try? await storage.saveSource(article)
                    // A recording with no speech in it has none on the next
                    // attempt either.
                    var heardNothing = false
                    if case .noSpeech? = error as? MeetingTranscriptionService.TranscriptionError { heardNothing = true }
                    let retry = !heardNothing && attempts + 1 < Self.zoomLocalRecordingTranscriptAttemptCap
                    await MainActor.run {
                        if heardNothing { _ = self.zoomLocalRecordingsWithoutSpeech.insert(folder.path) }
                        if retry {
                            self.zoomLocalRecordingRetryPending.insert(folder.path)
                        } else {
                            self.zoomLocalRecordingRetryPending.remove(folder.path)
                        }
                    }
                    log.error("Transcribing Zoom recording \(folder.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                await reloadSourcesAfterZoomLocalFiling(base: base, log: log)
            } catch {
                log.error("Filing Zoom recording \(folder.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The waiting recordings the learner has not ignored — what the Meetings
    /// tab shows. Settings › Sources shows `zoomLocalUnconvertedRecordings`
    /// whole, ignored ones included, so an Ignore can be taken back.
    var zoomLocalRecordingsAwaitingConversion: [ZoomLocalRecordingAwaitingConversion] {
        zoomLocalUnconvertedRecordings.filter { !zoomLocalRecordingIgnoredFolders.contains($0.folder.path) }
    }

    /// Hand a recording to Zoom to convert — the learner's own double-click:
    /// opening the `double_click_to_convert_01.zoom` file is exactly what the
    /// name says, Zoom writes the converted media into the same folder, and
    /// the watcher then files and transcribes it. When ForeverLM may use
    /// Accessibility it answers Zoom's "Files from unknown sources" dialog
    /// itself; when it may not, this click is where macOS asks, and the
    /// learner answers Zoom this once. False when nothing on this Mac opens
    /// `.zoom` files.
    @MainActor
    @discardableResult
    func convertZoomLocalRecordingInZoom(_ recording: ZoomLocalRecordingAwaitingConversion) -> Bool {
        if !AXIsProcessTrusted() {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        return Self.openZoomLocalRecordingInZoom(recording.folder, activate: true)
    }

    /// The open itself, shared with the automatic pass and the MCP twin.
    /// Only a folder the watcher itself listed is ever passed here — never a
    /// client-provided path. `activate` brings Zoom forward, which a
    /// learner's click wants and a background pass must not do. The dialog
    /// watch runs detached, so the caller never waits on Zoom; `completion`
    /// hears how it ended.
    @MainActor
    @discardableResult
    static func openZoomLocalRecordingInZoom(
        _ folder: ZoomLocalRecordingFolder,
        activate: Bool,
        completion: (@Sendable (ZoomUnknownSourceConfirmation) async -> Void)? = nil
    ) -> Bool {
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ZoomTranscriptWatcher")
        guard let rawPath = folder.unconvertedPath else { return false }
        let rawURL = URL(fileURLWithPath: rawPath)
        guard let zoomURL = NSWorkspace.shared.urlForApplication(toOpen: rawURL) else {
            log.error("Nothing on this Mac opens \(rawPath, privacy: .public); the recording stays unconverted")
            return false
        }
        let openedAt = Date()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        NSWorkspace.shared.open([rawURL], withApplicationAt: zoomURL, configuration: configuration) { _, error in
            if let error {
                log.error("Zoom did not open \(rawPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("Asked Zoom to convert \(folder.path, privacy: .public)")
        let folderPath = folder.path
        Task.detached(priority: .utility) {
            let outcome = await confirmZoomUnknownSourceDialog(folderPath: folderPath, openedAt: openedAt)
            log.info("Zoom's unknown-source check for \(folderPath, privacy: .public): \(String(describing: outcome), privacy: .public)")
            await completion?(outcome)
        }
        return true
    }

    // MARK: - Zoom's unknown-source dialog

    /// Zoom's converter, `Transcode.app`, verifies a recording's raw files
    /// before converting them, and a recording the meeting did not convert
    /// on the spot — Zoom quit, or a call that dropped and was restarted, as
    /// the 2026-09-25 standup was — fails that check however it is opened.
    /// Zoom then asks "Files from unknown sources" with **Convert Anyway** and
    /// **Do Not Convert**. It has no setting that trusts its own recording
    /// folder: in Transcode 7.1.9 the only route past the check is that
    /// button's `skipVerify`. So ForeverLM presses it, through Accessibility,
    /// and only on a dialog that names nothing but the raw files of the
    /// recording it just opened, shown by a Transcode that started after the
    /// open.
    ///
    /// The product owner (2026-09-25): "i always have to give permission for this in
    /// zoom; can you auto give permission?" — and, offered the choice, the
    /// fully automatic version over one that waits for his click.
    enum ZoomUnknownSourceConfirmation: Equatable, Sendable {
        /// ForeverLM pressed Convert Anyway and the dialog went.
        case pressed
        /// No such dialog came up: Zoom converted without asking, quit, or
        /// the watch ran out.
        case notAsked
        /// A dialog came up that ForeverLM would not answer — it named other
        /// files, or the press did not take — and was left to the learner.
        case leftForLearner
        /// ForeverLM may not use Accessibility, so the dialog is the learner's.
        case notAllowed
    }

    nonisolated static let zoomTranscodeBundleID = "us.zoom.Transcode"
    /// The process Zoom runs a meeting in. A conversion started under a
    /// meeting would take its CPU, so the automatic pass waits for it to end.
    nonisolated static let zoomMeetingBundleID = "us.zoom.CptHost"

    /// How long after an open ForeverLM watches for the dialog. Transcode
    /// opens its progress window within seconds, but the check that fails
    /// reads the raw files first, and a long meeting's are hundreds of MB.
    nonisolated static let zoomUnknownSourceDialogWait: TimeInterval = 5 * 60

    /// A Transcode window as Accessibility reads it: its buttons' names
    /// (Zoom leaves the title empty and puts the name in the description)
    /// and every piece of text in it.
    struct ZoomTranscodeWindowSnapshot: Equatable, Sendable {
        let buttons: [String]
        let texts: [String]
    }

    /// Every spelling of one Transcode button across the languages Zoom
    /// ships, from Transcode's own `InfoPlist.strings`, so the match holds in
    /// whatever language Zoom speaks. A Zoom that renames the button matches
    /// nothing, and its dialog is left alone rather than pressed wrongly. The
    /// key's numeric suffix is Zoom's string id, which a release may change.
    nonisolated static func zoomTranscodeButtonTitles(keyPrefix: String, transcodeBundle: URL) -> Set<String> {
        let resources = transcodeBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let languages = try? FileManager.default.contentsOfDirectory(
            at: resources, includingPropertiesForKeys: nil
        ) else { return [] }
        var titles: Set<String> = []
        for language in languages where language.pathExtension == "lproj" {
            let file = language.appendingPathComponent("InfoPlist.strings")
            guard let strings = NSDictionary(contentsOf: file) as? [String: String] else { continue }
            for (key, value) in strings where key.hasPrefix(keyPrefix) && !value.isEmpty {
                titles.insert(value)
            }
        }
        return titles
    }

    /// The `.zoom` file names a piece of the dialog's text lists.
    nonisolated static func zoomFileNames(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { $0.lowercased().hasSuffix(".zoom") }
    }

    /// Whether a Transcode window is the unknown-source dialog, and about
    /// nothing but files ForeverLM handed Zoom: it offers both Convert Anyway
    /// and Do Not Convert, names at least one `.zoom` file, and every file it
    /// names is a raw file of the recording just opened. Nil when the window
    /// is not that dialog at all.
    nonisolated static func zoomUnknownSourceDialogIsAbout(
        _ window: ZoomTranscodeWindowSnapshot,
        rawFileNames: Set<String>,
        convertTitles: Set<String>,
        declineTitles: Set<String>
    ) -> Bool? {
        guard window.buttons.contains(where: convertTitles.contains),
              window.buttons.contains(where: declineTitles.contains) else { return nil }
        let named = Set(window.texts.flatMap(zoomFileNames(in:)))
        return !named.isEmpty && named.isSubset(of: rawFileNames)
    }

    /// Read one window: its buttons with their elements, and its text. The
    /// walk is bounded — the dialog is a handful of elements — so a window
    /// with a deep tree cannot hold the watch.
    nonisolated static func zoomTranscodeWindowSnapshot(
        _ window: AXUIElement
    ) -> (snapshot: ZoomTranscodeWindowSnapshot, buttons: [(name: String, element: AXUIElement)]) {
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        var buttons: [(name: String, element: AXUIElement)] = []
        var texts: [String] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard visited <= 200 else { return }
            let role = string(element, kAXRoleAttribute) ?? ""
            let title = string(element, kAXTitleAttribute) ?? ""
            let description = string(element, kAXDescriptionAttribute) ?? ""
            if role == (kAXButtonRole as String) {
                let name = title.isEmpty ? description : title
                if !name.isEmpty { buttons.append((name, element)) }
            } else {
                for text in [title, description, string(element, kAXValueAttribute) ?? ""] where !text.isEmpty {
                    texts.append(text)
                }
            }
            guard depth < 6 else { return }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return (ZoomTranscodeWindowSnapshot(buttons: buttons.map(\.name), texts: texts), buttons)
    }

    /// A recording's raw files, and which of them iCloud has evicted.
    /// `~/Documents` is often an iCloud Drive folder, and a long meeting's
    /// raw file is hundreds of MB that Optimise Mac Storage takes back: the
    /// 2026-09-12 standup's 700 MB `double_click_to_convert_01.zoom` was
    /// dataless on 2026-09-25, and Zoom opened on it sat at 0% while the file
    /// came down, before it could even ask.
    nonisolated static func zoomLocalRecordingRawFiles(
        folderPath: String
    ) -> (names: Set<String>, evicted: [URL]) {
        let names = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? [])
                .filter { $0.lowercased().hasSuffix(".zoom") }
        )
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let evicted = names.sorted().map { folder.appendingPathComponent($0) }.filter { file in
            let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus else { return false }
            return status != .current
        }
        return (names, evicted)
    }

    /// Watch for Zoom's unknown-source dialog about the recording in
    /// `folderPath` and press Convert Anyway on it. Only a Transcode that
    /// started after the open counts, so a conversion already running for
    /// something else is never answered for it. A learner who allows
    /// Accessibility at the prompt their click raised is answered for within
    /// the same watch, and a watch over files iCloud is still bringing down
    /// lasts until they are here and then `wait` more. Off the main actor:
    /// Accessibility calls are messages to another process, and each is
    /// capped at a second.
    nonisolated static func confirmZoomUnknownSourceDialog(
        folderPath: String,
        openedAt: Date,
        wait: TimeInterval = zoomUnknownSourceDialogWait
    ) async -> ZoomUnknownSourceConfirmation {
        var raw = zoomLocalRecordingRawFiles(folderPath: folderPath)
        let rawFileNames = raw.names
        guard !rawFileNames.isEmpty else { return .notAsked }
        var deadline = openedAt.addingTimeInterval(wait)
        var rounds = 0
        var titles: [URL: (convert: Set<String>, decline: Set<String>)] = [:]
        var sawTranscode = false
        var trusted = false
        var presses = 0
        while Date() < deadline, !Task.isCancelled {
            rounds += 1
            if !raw.evicted.isEmpty && rounds % 15 == 0 {
                raw = zoomLocalRecordingRawFiles(folderPath: folderPath)
                // Bounded, so a download that never finishes cannot hold
                // the watch open for the rest of the launch.
                let extended = Date().addingTimeInterval(raw.evicted.isEmpty ? wait : 60)
                deadline = min(max(deadline, extended), openedAt.addingTimeInterval(2 * 3600))
            }
            guard AXIsProcessTrusted() else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            trusted = true
            let transcodes = NSRunningApplication.runningApplications(withBundleIdentifier: zoomTranscodeBundleID)
                .filter { !$0.isTerminated && ($0.launchDate ?? .distantPast) >= openedAt.addingTimeInterval(-2) }
            // Transcode quits once it has converted, and on Do Not Convert.
            if transcodes.isEmpty && sawTranscode { return presses > 0 ? .pressed : .notAsked }
            var dialogShowing = false
            for transcode in transcodes {
                sawTranscode = true
                guard let bundle = transcode.bundleURL else { continue }
                if titles[bundle] == nil {
                    titles[bundle] = (
                        zoomTranscodeButtonTitles(keyPrefix: "LN_Convert_Anyway_", transcodeBundle: bundle),
                        zoomTranscodeButtonTitles(keyPrefix: "LN_Do_Not_Convert_", transcodeBundle: bundle)
                    )
                }
                guard let known = titles[bundle], !known.convert.isEmpty, !known.decline.isEmpty else { continue }
                let app = AXUIElementCreateApplication(transcode.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 1)
                var windows: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
                      let list = windows as? [AXUIElement] else { continue }
                for window in list {
                    let read = zoomTranscodeWindowSnapshot(window)
                    guard let ours = zoomUnknownSourceDialogIsAbout(
                        read.snapshot,
                        rawFileNames: rawFileNames,
                        convertTitles: known.convert,
                        declineTitles: known.decline
                    ) else { continue }
                    guard ours else { return .leftForLearner }
                    dialogShowing = true
                    // A second press only if the first did not take; a
                    // dialog that outlives three is the learner's.
                    guard presses < 3 else { return .leftForLearner }
                    guard let button = read.buttons.first(where: { known.convert.contains($0.name) }) else { continue }
                    // Zoom's panel closes inside the press, so the call can
                    // report it could not complete although it did; the
                    // dialog going away is the proof, read next round.
                    _ = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
                    presses += 1
                }
            }
            if presses > 0 && !dialogShowing { return .pressed }
            try? await Task.sleep(for: .seconds(1))
        }
        guard trusted else { return .notAllowed }
        return presses > 0 ? .leftForLearner : .notAsked
    }

    // MARK: - Automatic conversion

    /// Automatic conversions per recording, ever. A recording Zoom cannot
    /// convert — damaged raw files, a conversion that stalls — must not be
    /// handed back at every pass; after this it waits on the Meetings tab for
    /// the learner, as every waiting recording did before.
    nonisolated static let zoomLocalRecordingAutoConversionCap = 2

    /// Folder path → automatic conversions made, on this Mac. Plain
    /// `UserDefaults` like the ignore list, pruned of folders that are gone.
    nonisolated static let zoomLocalRecordingAutoConversionsKey = "studio.zoomLocalRecordingAutoConversions"

    nonisolated static func zoomLocalRecordingAutoConversionsFromDefaults() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: zoomLocalRecordingAutoConversionsKey) as? [String: Int] ?? [:]
    }

    nonisolated static func saveZoomLocalRecordingAutoConversions(_ attempts: [String: Int]) {
        let kept = attempts.filter { FileManager.default.fileExists(atPath: $0.key) }
        if kept.isEmpty {
            UserDefaults.standard.removeObject(forKey: zoomLocalRecordingAutoConversionsKey)
        } else {
            UserDefaults.standard.set(kept, forKey: zoomLocalRecordingAutoConversionsKey)
        }
    }

    /// Which waiting recording the automatic pass hands Zoom next: the
    /// newest one not ignored and not already tried the capped number of
    /// times. `waiting` is newest first, as the watcher lists it.
    nonisolated static func zoomLocalRecordingToConvertAutomatically(
        _ waiting: [ZoomLocalRecordingFolder],
        ignored: Set<String>,
        attempts: [String: Int]
    ) -> ZoomLocalRecordingFolder? {
        waiting.first {
            !ignored.contains($0.path) && attempts[$0.path, default: 0] < zoomLocalRecordingAutoConversionCap
        }
    }

    /// Convert a waiting recording without the learner, now that ForeverLM
    /// can answer Zoom's dialog itself. Only when ForeverLM may use
    /// Accessibility — without it the open would be the dialog-at-every-launch
    /// of 2026-09-20 — and only while Zoom is neither in a meeting nor
    /// converting. One recording at a time: the next pass after Zoom quits
    /// takes the next one. Zoom is not brought forward.
    nonisolated func convertZoomLocalRecordingAutomatically(
        waiting: [ZoomLocalRecordingFolder],
        ignored: Set<String>
    ) async {
        guard !waiting.isEmpty, AXIsProcessTrusted() else { return }
        for bundleID in [Self.zoomTranscodeBundleID, Self.zoomMeetingBundleID]
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return
        }
        var attempts = Self.zoomLocalRecordingAutoConversionsFromDefaults()
        guard let folder = Self.zoomLocalRecordingToConvertAutomatically(
            waiting, ignored: ignored, attempts: attempts
        ) else { return }
        // Evicted files are brought down first, and Zoom is handed the
        // recording by a later pass once they are here, so its progress
        // window never sits at 0% over a download.
        let evicted = Self.zoomLocalRecordingRawFiles(folderPath: folder.path).evicted
        if !evicted.isEmpty {
            let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ZoomTranscriptWatcher")
            for file in evicted {
                do {
                    try FileManager.default.startDownloadingUbiquitousItem(at: file)
                } catch {
                    log.error("Downloading \(file.path, privacy: .public) from iCloud failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            log.info("Bringing \(folder.path, privacy: .public) down from iCloud before Zoom converts it")
            return
        }
        let claimed = await MainActor.run { () -> Bool in
            guard !self.zoomLocalRecordingAutoConversionInFlight else { return false }
            self.zoomLocalRecordingAutoConversionInFlight = true
            return true
        }
        guard claimed else { return }
        attempts[folder.path, default: 0] += 1
        Self.saveZoomLocalRecordingAutoConversions(attempts)
        let opened = await MainActor.run {
            Self.openZoomLocalRecordingInZoom(folder, activate: false) { _ in
                await MainActor.run { self.zoomLocalRecordingAutoConversionInFlight = false }
            }
        }
        if !opened {
            await MainActor.run { self.zoomLocalRecordingAutoConversionInFlight = false }
        }
    }

    /// Leave a recording alone: it stays in the Zoom folder, drops off the
    /// Meetings tab, and is never filed. Taken back with `ignored: false`.
    @MainActor
    func setZoomLocalRecordingIgnored(_ recording: ZoomLocalRecordingAwaitingConversion, _ ignored: Bool) {
        var folders = zoomLocalRecordingIgnoredFolders
        if ignored { folders.insert(recording.folder.path) } else { folders.remove(recording.folder.path) }
        guard folders != zoomLocalRecordingIgnoredFolders else { return }
        zoomLocalRecordingIgnoredFolders = folders
        Self.saveZoomLocalRecordingIgnoredFolders(folders)
    }

    /// File each settled transcript as a session of the series its topic
    /// names. Returns the IDs of the sessions this pass created; a transcript
    /// whose session already exists — filed by an earlier pass, or by hand
    /// over MCP under the same key — or that the learner removed is skipped,
    /// as is a series the learner removed, which a background pass must never
    /// bring back. `seriesParticipantLines` is each series' shared line for
    /// who was there (`zoomSeriesParticipantLines`), for a caption file whose
    /// cues name no one.
    nonisolated static func importZoomLocalTranscripts(
        _ files: [ZoomLocalTranscriptFile],
        storage: StorageService,
        removedGroupTitles: [String],
        seriesParticipantLines: [String: String] = [:]
    ) async -> [String] {
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "ZoomTranscriptWatcher")
        var inserted: [String] = []
        for file in files {
            if removedMeetingGroupTitles(removedGroupTitles, include: file.topic) {
                continue
            }
            do {
                let groupID: String
                let groups = try await storage.loadMeetingMetadata()
                if let series = zoomLocalRecordingSeriesID(topic: file.topic, groups: groups),
                   let resolved = try await storage.resolvedMeetingGroupID(matching: series) {
                    groupID = resolved
                } else if let existing = try await storage.resolvedMeetingGroupID(matching: file.topic) {
                    groupID = existing
                } else {
                    try await storage.saveMeetingGroup(name: file.topic, metadata: MeetingMetadata(title: file.topic))
                    groupID = file.topic
                }
                let sessionKey = readAISessionKey(title: file.topic, date: file.startedAt, includeTime: true)
                let url = zoomLocalTranscriptSessionURL(groupID: groupID, sessionKey: sessionKey)
                let name = zoomSessionName(topic: file.topic, seriesTitle: groups[groupID]?.title)
                let sessionTitle = readAISessionKey(title: name, date: file.startedAt, includeTime: true)

                // Reading the file is the expensive step; skip it for a session
                // that is already there. `insertSourceIfNew` re-checks below and
                // also honours the learner's removal of the session.
                if try await storage.sourceExistsByURL(url) != nil { continue }

                guard let raw = try? String(contentsOfFile: file.path, encoding: .utf8),
                      let transcript = formatZoomCaptionTranscript(raw) else {
                    log.info("Zoom transcript \(file.path, privacy: .public) holds no captions yet; skipped")
                    continue
                }

                var article = StudioArticle(
                    url: url,
                    title: sessionTitle,
                    sourceType: .meeting,
                    discoveryOrigin: .zoom,
                    parentGroup: groupID
                )
                article.domain = file.topic
                article.dateAdded = file.startedAt
                article.localFilePath = file.path
                article.content = "# \(sessionTitle)\n\n## Transcript\n\n\(transcript)"
                article.wordCount = article.content?.split(separator: " ").count
                article.state = .ready
                // Who was there, from the captions' own speaker labels.
                let speakers = Self.zoomCaptionSpeakers(transcript)
                article.author = Self.zoomSessionParticipantLine(speakers: speakers, invited: [])

                guard try await storage.insertSourceIfNew(&article) else { continue }
                let artifact = MeetingArtifact(
                    id: SourceIdentity.stableID(for: "\(article.id):zoom-local:transcript"),
                    sourceId: article.id,
                    groupId: groupID,
                    kind: .transcript,
                    title: "\(name) Transcript",
                    url: nil,
                    localFilePath: file.path,
                    mimeType: "text/plain",
                    modifiedAt: file.startedAt,
                    sortIndex: 0
                )
                try await storage.saveMeetingArtifact(artifact)
                inserted.append(article.id)
                // The meeting is on the Mac's Calendar, drawn there before it
                // happened; this is what was said in it. A caption file with no
                // speaker labels leaves the invitation, or else the people the
                // series always has, as the word on who was there.
                let invited = await MeetingCalendarEvent.invitedNames(startedAt: file.startedAt, title: file.topic)
                if article.author == nil,
                   let line = Self.zoomSessionParticipantLine(
                       speakers: speakers, invited: invited, series: seriesParticipantLines[groupID]
                   ) {
                    article.author = line
                    try await storage.saveSource(article, syncImmediately: true)
                }
                MeetingActionItemExtractor.shared.noteTranscriptReady(sourceID: article.id)
            } catch {
                log.error("Filing Zoom transcript \(file.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return inserted
    }
}
#endif
