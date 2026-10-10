import AVFoundation
import Testing
import Foundation
@testable import ForeverLM

/// Zoom's desktop client saves a caption transcript beside each local
/// recording. These pin how such a file is recognised, dated, folded into
/// readable lines, and keyed so a hand import and the watcher agree.
@Suite("Zoom local transcripts")
struct ZoomLocalTranscriptTests {

    @Test("the file name carries the topic and the start, in the offset it names")
    func fileNameParses() throws {
        let parsed = try #require(StudioViewModel.parseZoomLocalTranscriptFileName(
            "Robin <> Zara standup 2026-09-12 08:44(GMT-7:00).txt"
        ))
        #expect(parsed.topic == "Robin <> Zara standup")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed.startedAt)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 12)
        #expect(components.hour == 15)
        #expect(components.minute == 44)
    }

    @Test("a positive offset and a one-digit hour parse too")
    func positiveOffsetParses() throws {
        let parsed = try #require(StudioViewModel.parseZoomLocalTranscriptFileName(
            "Lab meeting 2026-01-05 09:00(GMT+1:00).txt"
        ))
        #expect(parsed.topic == "Lab meeting")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(calendar.component(.hour, from: parsed.startedAt) == 8)
    }

    @Test("other text files in the folder are not transcripts")
    func otherFilesAreIgnored() {
        #expect(StudioViewModel.parseZoomLocalTranscriptFileName("meeting_saved_chat.txt") == nil)
        #expect(StudioViewModel.parseZoomLocalTranscriptFileName("Robin <> Zara standup 2026-09-12 08:44.txt") == nil)
        #expect(StudioViewModel.parseZoomLocalTranscriptFileName("2026-09-12 08.44.39 Robin __ Zara standup") == nil)
        #expect(StudioViewModel.parseZoomLocalTranscriptFileName(" 2026-09-12 08:44(GMT-7:00).txt") == nil)
    }

    @Test("cues fold to one timestamped line each, in order")
    func captionsFold() throws {
        let raw = """
        08:45:50 --> 08:45:52
        Robin Vale: Hello, we are here.

        08:45:52 --> 08:45:54
        Zara Holt: How's it going?

        09:17:11 --> 09:17:13
        Robin Vale: See you.

        """
        let folded = try #require(StudioViewModel.formatZoomCaptionTranscript(raw))
        #expect(folded == """
        [08:45:50] Robin Vale: Hello, we are here.
        [08:45:52] Zara Holt: How's it going?
        [09:17:11] Robin Vale: See you.
        """)
    }

    @Test("a file without a single cue is not a transcript")
    func emptyCaptionsAreNil() {
        #expect(StudioViewModel.formatZoomCaptionTranscript("") == nil)
        #expect(StudioViewModel.formatZoomCaptionTranscript("Nothing was said.\n") == nil)
    }

    @Test("the session URL matches the transcript-file importer's shape")
    func sessionURLMatchesImporter() {
        let key = StudioViewModel.readAISessionKey(
            title: "Robin <> Zara standup",
            date: Date(timeIntervalSince1970: 0),
            includeTime: true
        )
        let url = StudioViewModel.zoomLocalTranscriptSessionURL(
            groupID: "zoom:examplefellowship.zoom.us",
            sessionKey: key
        )
        #expect(url == "meeting://zoom:examplefellowship.zoom.us/\(StudioViewModel.percentEncodedMeetingPathComponent(key))")
        #expect(url.hasPrefix("meeting://zoom:examplefellowship.zoom.us/Robin%20%3C%3E%20Zara%20standup%20-%20"))
    }

    @Test("only transcripts in the folder's top level are listed, dated by their names")
    func folderListing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-local-transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = root.appendingPathComponent("Robin <> Zara standup 2026-09-12 08:44(GMT-7:00).txt")
        try "08:45:50 --> 08:45:52\nRobin Vale: Hello.\n".write(to: transcript, atomically: true, encoding: .utf8)
        try "chat".write(to: root.appendingPathComponent("meeting_saved_chat.txt"), atomically: true, encoding: .utf8)
        let recordingFolder = root.appendingPathComponent("2026-09-12 08.44.39 Robin __ Zara standup")
        try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        try "x".write(to: recordingFolder.appendingPathComponent("Other 2026-09-12 08:44(GMT-7:00).txt"), atomically: true, encoding: .utf8)

        let files = StudioViewModel.zoomLocalTranscriptFiles(roots: [root.path])
        #expect(files.count == 1)
        #expect(files.first?.topic == "Robin <> Zara standup")
        #expect(files.first?.path == transcript.path)

        // The recording folder is in the snapshot too: what happens inside it
        // (Zoom converting) is a change the watcher must act on.
        let snapshot = StudioViewModel.zoomLocalTranscriptSnapshot(roots: [root.path])
        #expect(Set(snapshot.keys) == Set([transcript.path, recordingFolder.path]))
    }

    @Test("the chosen folder is watched ahead of Zoom's default, and neither is watched twice or when absent")
    func watchRoots() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-roots-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        let zoomDefault = home.appendingPathComponent("Documents/Zoom")
        let chosen = base.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        typealias VM = StudioViewModel

        // Zoom's default does not exist yet: only the chosen folder is watched,
        // and FSEvents is never armed on a folder that is not there.
        #expect(VM.zoomLocalTranscriptRoots(homeDir: home.path, customFolder: chosen.path) == [chosen.path])
        #expect(VM.zoomLocalTranscriptRoots(homeDir: home.path, customFolder: nil).isEmpty)

        // With both present the chosen folder comes first, because when it is
        // the live one the default is the empty leftover.
        try FileManager.default.createDirectory(at: zoomDefault, withIntermediateDirectories: true)
        #expect(VM.zoomLocalTranscriptRoots(homeDir: home.path, customFolder: chosen.path)
            == [chosen.path, zoomDefault.path])
        #expect(VM.zoomLocalTranscriptRoots(homeDir: home.path, customFolder: nil) == [zoomDefault.path])

        // Choosing the default folder itself must not watch it twice — nor when
        // the choice reaches it by a different spelling. This is the case that
        // matters on a Mac where ~/Documents is a symlink into a file-sync
        // folder: the two paths are one folder.
        #expect(VM.zoomLocalTranscriptRoots(homeDir: home.path, customFolder: zoomDefault.path)
            == [zoomDefault.path])
        let link = base.appendingPathComponent("link-to-default")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zoomDefault)
        #expect(VM.zoomLocalTranscriptRoots(homeDir: home.path, customFolder: link.path) == [link.path])

        // A file, or a folder that has been deleted, is not a watch root.
        let file = base.appendingPathComponent("notes.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(!VM.isReadableZoomTranscriptFolder(file.path))
        #expect(!VM.isReadableZoomTranscriptFolder(base.appendingPathComponent("gone").path))
    }

    // MARK: - Recording folders

    @Test("a recording folder's name carries Zoom's file-safe topic and the start, in the Mac's zone")
    func recordingFolderNameParses() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let parsed = try #require(StudioViewModel.parseZoomLocalRecordingFolderName(
            "2026-09-19 08.30.13 Robin __ Zara", timeZone: zone
        ))
        #expect(parsed.topic == "Robin __ Zara")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed.startedAt)
        #expect(components.year == 2026 && components.month == 9 && components.day == 19)
        #expect(components.hour == 8 && components.minute == 30 && components.second == 13)

        #expect(StudioViewModel.parseZoomLocalRecordingFolderName("Robin <> Zara standup 2026-09-12 08:44(GMT-7:00).txt") == nil)
        #expect(StudioViewModel.parseZoomLocalRecordingFolderName(".tmp.drivedownload") == nil)
        #expect(StudioViewModel.parseZoomLocalRecordingFolderName("2026-09-19 08.30.13 ") == nil)
    }

    @Test("a title is spelled the way Zoom writes it into a file name")
    func fileNameTopic() {
        #expect(StudioViewModel.zoomFileNameTopic("Robin <> Zara") == "Robin __ Zara")
        #expect(StudioViewModel.zoomFileNameTopic("Robin <> Zara standup") == "Robin __ Zara standup")
        #expect(StudioViewModel.zoomFileNameTopic(" Lab meeting: week 2 / review? ") == "Lab meeting_ week 2 _ review_")
    }

    @Test("recording.conf names the converted media, audio first, and nothing before conversion")
    func recordingConfMedia() {
        let converted = Data(#"{"magic_number":"326666952","items":[{"process":100,"audio":"audio1326666952.m4a","prefix":"","video":"video1326666952.mp4"}]}"#.utf8)
        #expect(StudioViewModel.zoomConvertedMediaNames(inRecordingConf: converted) == ["audio1326666952.m4a", "video1326666952.mp4"])
        let raw = Data(#"{"magic_number":"561787723"}"#.utf8)
        #expect(StudioViewModel.zoomConvertedMediaNames(inRecordingConf: raw).isEmpty)
        let converting = Data(#"{"magic_number":"1","items":[{"process":40,"audio":"audio1.m4a","video":"video1.mp4"}]}"#.utf8)
        #expect(StudioViewModel.zoomConvertedMediaNames(inRecordingConf: converting).isEmpty)
        #expect(StudioViewModel.zoomConvertedMediaNames(inRecordingConf: Data("not json".utf8)).isEmpty)
    }

    @Test("recording folders are listed with their media or their raw file, and a meeting run over into a second slot is two of them")
    func recordingFoldersAreListed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-local-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("2026-09-19 08.30.13 Robin __ Zara")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try #"{"magic_number":"1","items":[{"process":100,"audio":"audio1.m4a","video":"video1.mp4"}]}"#
            .write(to: first.appendingPathComponent("recording.conf"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: first.appendingPathComponent("audio1.m4a"))
        try Data([0]).write(to: first.appendingPathComponent("video1.mp4"))

        let second = root.appendingPathComponent("2026-09-19 09.10.32 Robin __ Zara")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try #"{"magic_number":"2"}"#.write(to: second.appendingPathComponent("recording.conf"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: second.appendingPathComponent("double_click_to_convert_02.zoom"))
        try Data([0]).write(to: second.appendingPathComponent("double_click_to_convert_01.zoom"))

        // A converted folder whose media is gone offers nothing to read.
        let emptied = root.appendingPathComponent("2026-09-14 09.00.12 Robin __ Zara standup")
        try FileManager.default.createDirectory(at: emptied, withIntermediateDirectories: true)
        try #"{"magic_number":"3","items":[{"process":100,"audio":"audio3.m4a","video":"video3.mp4"}]}"#
            .write(to: emptied.appendingPathComponent("recording.conf"), atomically: true, encoding: .utf8)

        try "chat".write(to: root.appendingPathComponent("meeting_saved_chat.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".tmp.driveupload"), withIntermediateDirectories: true)

        let folders = StudioViewModel.zoomLocalRecordingFolders(roots: [root.path])
        #expect(folders.map(\.path) == [emptied.path, first.path, second.path])
        #expect(folders[1].folderTopic == "Robin __ Zara")
        #expect(folders[1].mediaPath == first.appendingPathComponent("audio1.m4a").path)
        #expect(folders[1].unconvertedPath == nil)
        #expect(folders[2].mediaPath == nil)
        #expect(folders[2].unconvertedPath == second.appendingPathComponent("double_click_to_convert_01.zoom").path)
        #expect(folders[0].mediaPath == nil && folders[0].unconvertedPath == nil)

        // Two folders, two sessions: the keys carry their own starts.
        let keys = folders.dropFirst().map {
            StudioViewModel.readAISessionKey(title: "Robin <> Zara", date: $0.startedAt, includeTime: true)
        }
        #expect(keys.count == 2 && keys[0] != keys[1])

        // The snapshot gates on folders as well as caption files.
        let snapshot = StudioViewModel.zoomLocalTranscriptSnapshot(roots: [root.path])
        #expect(Set(snapshot.keys) == Set([emptied.path, first.path, second.path]))
    }

    @Test("the real title comes back from the series and the calendar, and a caption file covers its own recording only")
    func topicRecoveryAndCaptionCoverage() throws {
        #expect(StudioViewModel.zoomLocalRecordingTopic(
            folderTopic: "Robin __ Zara",
            knownTitles: ["Robin <> Zara standup", "Lab meeting", "Robin <> Zara"]
        ) == "Robin <> Zara")
        #expect(StudioViewModel.zoomLocalRecordingTopic(
            folderTopic: "robin __ zara standup",
            knownTitles: [" Robin <> Zara standup "]
        ) == "Robin <> Zara standup")
        #expect(StudioViewModel.zoomLocalRecordingTopic(folderTopic: "Robin __ Zara", knownTitles: ["Lab meeting"]) == "Robin __ Zara")
        // A series made from a folder's spelling, merged away since, matches
        // every folder of that meeting and must not outrank the calendar.
        #expect(StudioViewModel.zoomLocalRecordingTopic(
            folderTopic: "Robin __ Zara",
            knownTitles: ["Robin __ Zara", "Robin <> Zara standup", "Robin <> Zara"]
        ) == "Robin <> Zara")
        #expect(StudioViewModel.zoomLocalRecordingTopic(
            folderTopic: "Robin __ Zara", knownTitles: ["Robin __ Zara", "Lab meeting"]
        ) == "Robin __ Zara")
        #expect(StudioViewModel.zoomLocalRecordingTopic(folderTopic: "lab meeting", knownTitles: ["Lab meeting"]) == "Lab meeting")

        let start = try #require(StudioViewModel.parseZoomLocalTranscriptFileName(
            "Robin <> Zara standup 2026-09-12 08:44(GMT-7:00).txt"
        )).startedAt
        let caption = StudioViewModel.ZoomLocalTranscriptFile(
            path: "/z/Robin <> Zara standup 2026-09-12 08:44(GMT-7:00).txt",
            topic: "Robin <> Zara standup", startedAt: start, modifiedAt: start
        )
        func folder(_ topic: String, offset: TimeInterval) -> StudioViewModel.ZoomLocalRecordingFolder {
            StudioViewModel.ZoomLocalRecordingFolder(
                path: "/z/f", folderTopic: topic, startedAt: start.addingTimeInterval(offset),
                modifiedAt: start, mediaPath: nil, unconvertedPath: nil
            )
        }
        #expect(StudioViewModel.zoomLocalRecordingIsCaptioned(folder("Robin __ Zara standup", offset: 39), captions: [caption]))
        #expect(!StudioViewModel.zoomLocalRecordingIsCaptioned(folder("Robin __ Zara standup", offset: 40 * 60), captions: [caption]))
        #expect(!StudioViewModel.zoomLocalRecordingIsCaptioned(folder("Robin __ Zara", offset: 39), captions: [caption]))
    }

    @Test("only a raw recording left still for fifteen minutes and covered by no caption waits for the learner, newest first")
    func recordingsNeedingConversion() {
        // The product owner (2026-09-20), on Zoom's unknown-source dialog opening at
        // every launch over the recording of a meeting he had ended because
        // it did not happen: the pass lists what only Zoom can convert. It
        // opens one in Zoom only when ForeverLM can answer that dialog.
        let now = Date()
        func folder(
            _ path: String, startedAgo: TimeInterval, writtenAgo: TimeInterval, raw: Bool, media: Bool = false
        ) -> StudioViewModel.ZoomLocalRecordingFolder {
            StudioViewModel.ZoomLocalRecordingFolder(
                path: path, folderTopic: "Robin __ Zara",
                startedAt: now.addingTimeInterval(-startedAgo), modifiedAt: now.addingTimeInterval(-writtenAgo),
                mediaPath: media ? "\(path)/audio1.m4a" : nil,
                unconvertedPath: raw ? "\(path)/double_click_to_convert_01.zoom" : nil
            )
        }
        let older = folder("/z/older", startedAgo: 3 * 3600, writtenAgo: 3 * 3600, raw: true)
        let newer = folder("/z/newer", startedAgo: 3600, writtenAgo: 20 * 60, raw: true)
        // Written a minute ago: Zoom may still be converting it.
        let converting = folder("/z/converting", startedAgo: 600, writtenAgo: 60, raw: true)
        let converted = folder("/z/converted", startedAgo: 7200, writtenAgo: 7000, raw: false, media: true)
        let emptied = folder("/z/emptied", startedAgo: 7200, writtenAgo: 7000, raw: false)
        let captioned = folder("/z/captioned", startedAgo: 5 * 3600, writtenAgo: 5 * 3600, raw: true)
        let caption = StudioViewModel.ZoomLocalTranscriptFile(
            path: "/z/Robin <> Zara 2026-09-20 08:30(GMT-7:00).txt", topic: "Robin <> Zara",
            startedAt: captioned.startedAt.addingTimeInterval(20), modifiedAt: captioned.startedAt
        )
        let waiting = StudioViewModel.zoomLocalRecordingsNeedingConversion(
            [older, converting, converted, emptied, captioned, newer], captions: [caption], now: now
        )
        #expect(waiting.map(\.path) == ["/z/newer", "/z/older"])
        // Fifteen minutes later the one Zoom was still converting has either
        // converted, or is waiting too.
        let later = StudioViewModel.zoomLocalRecordingsNeedingConversion(
            [converting], captions: [], now: now.addingTimeInterval(StudioViewModel.zoomLocalRecordingConversionWait)
        )
        #expect(later.map(\.path) == ["/z/converting"])
    }

    @Test("a renamed series keeps filing into the group its longer name made, unless two groups could be meant")
    func seriesResolution() {
        let groups: [String: MeetingMetadata] = [
            "zoom:examplefellowship.zoom.us": MeetingMetadata(title: "Robin <> Zara standup"),
            "lab": MeetingMetadata(title: "Lab meeting"),
        ]
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "Robin <> Zara", groups: groups) == "zoom:examplefellowship.zoom.us")
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "robin <> zara standup", groups: groups) == "zoom:examplefellowship.zoom.us")
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "Robin __ Zara", groups: groups) == "zoom:examplefellowship.zoom.us")
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "Lab", groups: groups) == "lab")
        // "Labs" is not "Lab meeting"; the prefix is a whole word.
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "La", groups: groups) == nil)
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "Robin <> Zara", groups: groups.merging(
            ["retro": MeetingMetadata(title: "Robin <> Zara retro")], uniquingKeysWith: { a, _ in a }
        )) == nil)
        var merged = MeetingMetadata(title: "Robin <> Zara standup")
        merged.mergedIntoGroupID = "elsewhere"
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "Robin <> Zara", groups: ["old": merged]) == nil)
        #expect(StudioViewModel.zoomLocalRecordingSeriesID(topic: "  ", groups: groups) == nil)
    }

    /// Folders the way Zoom wrote them on 2026-09-21: the standup's scheduled
    /// call, cut by the free account's forty minutes, and the reconnect in
    /// the host's personal room 49 s later.
    private func folder(_ name: String, media: Bool = true) -> StudioViewModel.ZoomLocalRecordingFolder {
        let parsed = StudioViewModel.parseZoomLocalRecordingFolderName(name)!
        return StudioViewModel.ZoomLocalRecordingFolder(
            path: "/zoom/" + name,
            folderTopic: parsed.topic,
            startedAt: parsed.startedAt,
            modifiedAt: parsed.startedAt,
            mediaPath: media ? "/zoom/" + name + "/audio1.m4a" : nil,
            unconvertedPath: media ? nil : "/zoom/" + name + "/double_click_to_convert_01.zoom"
        )
    }

    /// A recording's end as its files say it: its media ran `length`, and
    /// Zoom wrote the converted media at `writtenAt` — the media's own end
    /// when nil, the way a call recorded to its end reads.
    private func end(
        _ folder: StudioViewModel.ZoomLocalRecordingFolder, _ length: TimeInterval, writtenAt: Date? = nil
    ) -> StudioViewModel.ZoomLocalRecordingEnd {
        StudioViewModel.ZoomLocalRecordingEnd(startedAt: folder.startedAt, duration: length, mediaWrittenAt: writtenAt)!
    }

    @Test("a personal-room topic is Zoom's name for the host's room, not a meeting's title")
    func personalRoomTopic() {
        #expect(StudioViewModel.zoomLocalRecordingIsPersonalRoomTopic("Robin Vale's Zoom Meeting"))
        #expect(StudioViewModel.zoomLocalRecordingIsPersonalRoomTopic("Zara's Personal Meeting Room"))
        #expect(StudioViewModel.zoomLocalRecordingIsPersonalRoomTopic("  zoom meeting "))
        #expect(!StudioViewModel.zoomLocalRecordingIsPersonalRoomTopic("Robin <> Zara"))
        #expect(!StudioViewModel.zoomLocalRecordingIsPersonalRoomTopic("Zoom Meeting notes"))
    }

    @Test("a recording that begins within minutes of the previous one's end continues it, whatever its room is named")
    func reconnectContinuesTheFirstCall() {
        let first = folder("2026-09-21 08.32.51 Robin __ Zara")
        let reconnect = folder("2026-09-21 09.13.06 Robin Vale's Zoom Meeting")
        // The first call's media ran 39 min 26 s: it ended at 09:12:17.
        let firstLength: TimeInterval = 2365.865

        #expect(StudioViewModel.zoomLocalRecordingMayContinue(reconnect, first))
        #expect(StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: end(first, firstLength)))
        // A length nobody measured decides nothing.
        #expect(!StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: nil))
        #expect(StudioViewModel.ZoomLocalRecordingEnd(startedAt: first.startedAt, duration: nil, mediaWrittenAt: nil) == nil)
        #expect(StudioViewModel.ZoomLocalRecordingEnd(startedAt: first.startedAt, duration: 0, mediaWrittenAt: nil) == nil)
        // Had the first call ended at 08:50, a 09:13 call is a new meeting.
        #expect(!StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: end(first, 18 * 60)))
        // A reconnect never begins before the call it continues has ended,
        // beyond the clock's minute.
        #expect(StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: end(first, 2415 + 30)))
        #expect(!StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: end(first, 2415 + 120)))
        // The order is the recordings' own.
        #expect(!StudioViewModel.zoomLocalRecordingMayContinue(first, reconnect))

        // Another scheduled meeting right after is its own meeting, gap or no gap.
        let lab = folder("2026-09-21 09.13.06 Lab meeting")
        #expect(!StudioViewModel.zoomLocalRecordingMayContinue(lab, first))
        #expect(!StudioViewModel.zoomLocalRecordingContinues(lab, first, previousEnd: end(first, firstLength)))
        // The same topic again, minutes later, continues too (2026-09-19's pair).
        let sameTopic = folder("2026-09-21 09.13.06 Robin __ Zara")
        #expect(StudioViewModel.zoomLocalRecordingContinues(sameTopic, first, previousEnd: end(first, firstLength)))
        // The next morning's call in the host's room is not last night's.
        let tomorrow = folder("2026-09-22 09.13.06 Robin Vale's Zoom Meeting")
        #expect(!StudioViewModel.zoomLocalRecordingMayContinue(tomorrow, first))
    }

    @Test("a recording stopped before its call ended is continued by a call that begins before Zoom wrote the media")
    func recordingStoppedEarlyIsStillContinued() {
        // 2026-09-30: the standup's recording was stopped at 08:40:29 early,
        // the free account cut the call at 09:11, Zoom wrote
        // the converted media at 09:11:55, and the reconnect in the host's
        // room began at 09:11:26.
        let first = folder("2026-09-30 08.31.20 Robin __ Zara")
        let reconnect = folder("2026-09-30 09.11.26 Robin Vale's Personal Meeting Room")
        let written = first.startedAt.addingTimeInterval(40 * 60 + 35)
        let recorded: TimeInterval = 549.033
        let callEnd = end(first, recorded, writtenAt: written)
        #expect(callEnd.noEarlierThan == first.startedAt.addingTimeInterval(recorded))
        #expect(callEnd.noLaterThan == written)
        #expect(StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: callEnd))
        #expect(StudioViewModel.zoomLocalRecordingHeads(
            [reconnect, first], ends: [first.path: callEnd]
        )[reconnect.path]?.path == first.path)
        // The media alone says the call ended at 08:40, and a 09:11 call
        // would be a meeting of its own.
        #expect(!StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: end(first, recorded)))
        // The call may have ended anywhere between the recording's stop and
        // the media's write, so a reconnect begun in between follows too.
        let between = folder("2026-09-30 08.55.00 Robin Vale's Personal Meeting Room")
        #expect(StudioViewModel.zoomLocalRecordingContinues(between, first, previousEnd: callEnd))
        // Past the gap after the write, it is a new meeting.
        let later = folder("2026-09-30 09.22.00 Robin Vale's Personal Meeting Room")
        #expect(!StudioViewModel.zoomLocalRecordingContinues(later, first, previousEnd: callEnd))
        // A write earlier than the media's own end — a copied folder —
        // bounds nothing beyond the media.
        let copied = end(first, recorded, writtenAt: first.startedAt)
        #expect(copied.noLaterThan == copied.noEarlierThan)
        #expect(!StudioViewModel.zoomLocalRecordingContinues(reconnect, first, previousEnd: copied))
    }

    @Test("a chain of reconnects all name the call the chain began with, and an unconverted call is continued by nothing")
    func reconnectChainsToTheHead() {
        let first = folder("2026-09-19 08.30.13 Robin __ Zara")
        let second = folder("2026-09-19 09.10.32 Robin __ Zara")
        let third = folder("2026-09-19 09.51.00 Robin Vale's Zoom Meeting")
        let afternoon = folder("2026-09-19 14.00.00 Robin Vale's Zoom Meeting")
        // Out of order on purpose: the rule sorts.
        let heads = StudioViewModel.zoomLocalRecordingHeads(
            [third, afternoon, first, second],
            ends: [first.path: end(first, 40 * 60 - 20), second.path: end(second, 40 * 60 - 12)]
        )
        #expect(heads[second.path]?.path == first.path)
        #expect(heads[third.path]?.path == first.path)
        #expect(heads[first.path] == nil)
        #expect(heads[afternoon.path] == nil)

        // The second call's length unknown: the third stands alone.
        let partial = StudioViewModel.zoomLocalRecordingHeads(
            [first, second, third], ends: [first.path: end(first, 40 * 60 - 20)]
        )
        #expect(partial[second.path]?.path == first.path)
        #expect(partial[third.path] == nil)

        // A raw first call has no length to measure.
        let raw = folder("2026-09-19 08.30.13 Robin __ Zara", media: false)
        #expect(StudioViewModel.zoomLocalRecordingHeads([raw, second], ends: [:]).isEmpty)
    }

    @Test("who was there is read off the captions' speaker labels, once each, in order of first word")
    func speakersComeFromCaptionLabels() {
        let transcript = """
        [08:45:50] Robin Vale: Hello, we are here.
        [08:45:52] Robin Vale: We made it.
        [08:45:52] Zara Holt: How's it going?
        [08:45:54] Robin Vale: Good, how are you? Note: not a speaker.
        [08:46:01] Alan (Kai) Young: Hi both.
        """
        #expect(StudioViewModel.zoomCaptionSpeakers(transcript) == ["Robin Vale", "Zara Holt", "Alan (Kai) Young"])
    }

    @Test("a transcript ForeverLM wrote itself names nobody, and nobody is guessed")
    func unlabelledTranscriptNamesNobody() {
        let transcript = "Hello. Good morning. Good afternoon, good evening for you, yeah.\nWell, afternoon, I guess. Yeah, how's life?"
        #expect(StudioViewModel.zoomCaptionSpeakers(transcript).isEmpty)
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: [], invited: []) == nil)
    }

    @Test("the session's line is who spoke, else who was invited, on one comma-separated line")
    func participantLinePrefersSpeakers() {
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: ["Zara Holt", "Robin Vale"], invited: ["Robin Vale", "zara@example.org"]) == "Zara Holt, Robin Vale")
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: [], invited: ["Robin Vale", "zara@example.org"]) == "Robin Vale, zara@example.org")
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: [], invited: ["  "]) == nil)
    }

    @Test("the series' shared line names a session its own records name only by address, or not at all")
    func participantLineFallsBackToTheSeries() {
        let series = "Robin Vale, Zara Holt"
        // The standup's Google invitation: one guest, by address, no host.
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: [], invited: ["zara.holt@example.org"], series: series) == series)
        // Moved off its calendar slot: no invitation at all.
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: [], invited: [], series: series) == series)
        // What the session's own records say by name still wins.
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: ["Zara Holt"], invited: [], series: series) == "Zara Holt")
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: [], invited: ["Zara Holt", "Alan Young"], series: series) == "Zara Holt, Alan Young")
        // No series line: the address, as before.
        #expect(StudioViewModel.zoomSessionParticipantLine(speakers: [], invited: ["zara.holt@example.org"], series: nil) == "zara.holt@example.org")
    }

    @Test("a series has a shared line only when most of its named sessions agree")
    func seriesLineNeedsAMajority() {
        let pair = "Robin Vale, Zara Holt"
        #expect(StudioViewModel.zoomSeriesParticipantLine([pair, pair, nil, "", "zara.holt@example.org", "Robin Vale, zara@x.org"]) == pair)
        #expect(StudioViewModel.zoomSeriesParticipantLine([pair, pair, "Robin Vale, Zara Holt, Alan Young"]) == pair)
        // One session is no pattern; a split room is none either.
        #expect(StudioViewModel.zoomSeriesParticipantLine([pair, nil]) == nil)
        #expect(StudioViewModel.zoomSeriesParticipantLine([pair, pair, "Ann", "Ann"]) == nil)
        #expect(StudioViewModel.zoomSeriesParticipantLine(["Ann", "Bob", "Cy"]) == nil)
    }

    @Test("a session is titled after the series it files into, whatever its file spelled")
    func sessionIsNamedAfterItsSeries() {
        let series = "Robin <> Zara standup"
        #expect(StudioViewModel.zoomSessionName(topic: "Robin __ Zara", seriesTitle: series) == series)
        #expect(StudioViewModel.zoomSessionName(topic: "Robin <> Zara", seriesTitle: series) == series)
        #expect(StudioViewModel.zoomSessionName(topic: "Robin <> Zara standup", seriesTitle: series) == series)
        // A topic that says more than the series, or something else, keeps its name.
        #expect(StudioViewModel.zoomSessionName(topic: "Acme Lab Nexus - Journal Club", seriesTitle: "Acme Lab Nexus") == "Acme Lab Nexus - Journal Club")
        #expect(StudioViewModel.zoomSessionName(topic: "Lab meeting", seriesTitle: series) == "Lab meeting")
        #expect(StudioViewModel.zoomSessionName(topic: "Lab meeting", seriesTitle: nil) == "Lab meeting")
        let key = StudioViewModel.readAISessionKey(
            title: StudioViewModel.zoomSessionName(topic: "Robin __ Zara", seriesTitle: series),
            date: StudioViewModel.meetingDate(from: "2026/09/28 10:02"), includeTime: true
        )
        #expect(key == "Robin <> Zara standup - 2026/09/28 10:02")
    }

    @Test("the automatic pass takes the newest waiting recording not ignored and not tried twice")
    func automaticConversionChoosesNewestUntried() {
        let now = Date()
        func folder(_ path: String, startedAgo: TimeInterval) -> StudioViewModel.ZoomLocalRecordingFolder {
            StudioViewModel.ZoomLocalRecordingFolder(
                path: path, folderTopic: "Robin __ Zara",
                startedAt: now.addingTimeInterval(-startedAgo), modifiedAt: now.addingTimeInterval(-startedAgo),
                mediaPath: nil, unconvertedPath: "\(path)/double_click_to_convert_01.zoom"
            )
        }
        // Newest first, as zoomLocalRecordingsNeedingConversion lists them.
        let waiting = [folder("/z/today", startedAgo: 3600), folder("/z/yesterday", startedAgo: 86_400), folder("/z/older", startedAgo: 3 * 86_400)]
        let cap = StudioViewModel.zoomLocalRecordingAutoConversionCap
        #expect(StudioViewModel.zoomLocalRecordingToConvertAutomatically(waiting, ignored: [], attempts: [:])?.path == "/z/today")
        #expect(StudioViewModel.zoomLocalRecordingToConvertAutomatically(
            waiting, ignored: ["/z/today"], attempts: ["/z/yesterday": cap]
        )?.path == "/z/older")
        #expect(StudioViewModel.zoomLocalRecordingToConvertAutomatically(
            waiting, ignored: [], attempts: ["/z/today": cap - 1]
        )?.path == "/z/today")
        // Every one tried the capped number of times: it waits on the
        // Meetings tab for the learner, and Zoom is not opened again.
        #expect(StudioViewModel.zoomLocalRecordingToConvertAutomatically(
            waiting, ignored: [], attempts: ["/z/today": cap, "/z/yesterday": cap, "/z/older": cap]
        ) == nil)
    }

    @Test("Convert Anyway is pressed only on the unknown-source dialog, and only when it names nothing but this recording's raw files")
    func unknownSourceDialogMatch() {
        let convert: Set<String> = ["Convert Anyway", "Toch converteren"]
        let decline: Set<String> = ["Do Not Convert", "Niet converteren"]
        let raw: Set<String> = ["double_click_to_convert_01.zoom", "double_click_to_convert_02.zoom"]
        func about(_ buttons: [String], _ texts: [String]) -> Bool? {
            StudioViewModel.zoomUnknownSourceDialogIsAbout(
                StudioViewModel.ZoomTranscodeWindowSnapshot(buttons: buttons, texts: texts),
                rawFileNames: raw, convertTitles: convert, declineTitles: decline
            )
        }
        // The dialog of 2026-09-25, as Transcode 7.1.9 shows it: the file
        // names in one text, a line each.
        let message = "Converting the following files may put your device and personal data at risk.\ndouble_click_to_convert_01.zoom\ndouble_click_to_convert_02.zoom"
        #expect(about(["Convert Anyway", "Do Not Convert"], ["Files from unknown sources", message]) == true)
        // Zoom in Dutch.
        #expect(about(["Toch converteren", "Niet converteren"], ["double_click_to_convert_01.zoom"]) == true)
        // A file this open did not hand Zoom: the learner's to answer.
        #expect(about(["Convert Anyway", "Do Not Convert"], ["double_click_to_convert_01.zoom", "other_meeting.zoom"]) == false)
        // No file named at all: nothing to check the dialog against.
        #expect(about(["Convert Anyway", "Do Not Convert"], ["Files from unknown sources"]) == false)
        // Transcode's other windows are not the dialog: its progress window,
        // and the files-lost alert, which lists the same names.
        #expect(about(["Stop Converting"], ["Converting meeting recording"]) == nil)
        #expect(about(["OK"], ["Cannot find the files to convert.", message]) == nil)
        #expect(about(["Continue Transcode", "Stop"], ["Stop Converting"]) == nil)
    }

    @Test("the file names are read out of the dialog's text however Zoom separates them")
    func zoomFileNamesInText() {
        #expect(StudioViewModel.zoomFileNames(in: "risk.\ndouble_click_to_convert_01.zoom\ndouble_click_to_convert_02.zoom") == [
            "double_click_to_convert_01.zoom", "double_click_to_convert_02.zoom",
        ])
        #expect(StudioViewModel.zoomFileNames(in: "a.ZOOM, b.zoom") == ["a.ZOOM", "b.zoom"])
        #expect(StudioViewModel.zoomFileNames(in: "Files from unknown sources").isEmpty)
    }

}

/// A speech model handed silence makes something up — "Thank you for
/// watching.", a Russian letter, a Spanish sign-off — so a recording is
/// measured before any of it is sent. These pin the rule: at least a second
/// of 100 ms windows at −50 dBFS RMS or louder is speech, and nothing else is.
@Suite("Recording speech level")
struct RecordingSpeechLevelTests {

    private static let rate = RecordingSpeechLevel.sampleRate

    /// A square wave whose RMS is exactly `dBFS`, window-aligned when
    /// `seconds` is a whole number of windows.
    private static func tone(dBFS: Double, seconds: Double) -> [Float] {
        let amplitude = Float(pow(10, dBFS / 20))
        return (0..<Int((seconds * Self.rate).rounded())).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int((seconds * Self.rate).rounded()))
    }

    @Test("digital silence has no speech and no loudest window")
    func digitalSilence() {
        let level = RecordingSpeechLevel.measure(samples: Self.silence(seconds: 64), sampleRate: Self.rate)
        #expect(!level.hasSpeech)
        #expect(level.speechSeconds == 0)
        #expect(level.loudestWindowDBFS == -.infinity)
        #expect(abs(level.measuredSeconds - 64) < 0.001)
    }

    @Test("a call nobody spoke in, as Zoom records it, has no speech")
    func zoomSilence() {
        // The quietest of the five silent standups on 2026-09-28 sat near
        // −90 dBFS, and the loudest reached −52.5 dBFS for 0.2 s.
        let samples = Self.tone(dBFS: -90, seconds: 30)
            + Self.tone(dBFS: -52.5, seconds: 0.2)
            + Self.tone(dBFS: -90, seconds: 30)
        let level = RecordingSpeechLevel.measure(samples: samples, sampleRate: Self.rate)
        #expect(!level.hasSpeech)
        #expect(level.speechSeconds == 0)
        #expect(abs(level.loudestWindowDBFS - -52.5) < 0.01)
    }

    @Test("a click or a scrape is loud but too short to be speech")
    func clicksAreNotSpeech() {
        var samples = Self.tone(dBFS: -85, seconds: 60)
        // Nine separate 20 ms clicks at −6 dBFS peak: nine loud windows.
        for second in 1...9 {
            let start = second * 5 * Int(Self.rate)
            for index in start..<(start + 320) { samples[index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
        }
        let level = RecordingSpeechLevel.measure(samples: samples, sampleRate: Self.rate)
        #expect(!level.hasSpeech)
        #expect(abs(level.speechSeconds - 0.9) < 0.001)
        #expect(level.loudestWindowDBFS > -20)
    }

    @Test("a second at speech level is speech, and a tenth less is not")
    func oneSecondIsTheLine() {
        let under = Self.silence(seconds: 20) + Self.tone(dBFS: -45, seconds: 0.9) + Self.silence(seconds: 20)
        let at = Self.silence(seconds: 20) + Self.tone(dBFS: -45, seconds: 1.0) + Self.silence(seconds: 20)
        #expect(!RecordingSpeechLevel.measure(samples: under, sampleRate: Self.rate).hasSpeech)
        #expect(RecordingSpeechLevel.measure(samples: at, sampleRate: Self.rate).hasSpeech)
    }

    @Test("the floor is −50 dBFS: just over it is speech, just under it is not")
    func floorIsMinusFifty() {
        let over = RecordingSpeechLevel.measure(samples: Self.tone(dBFS: -49.5, seconds: 2), sampleRate: Self.rate)
        let under = RecordingSpeechLevel.measure(samples: Self.tone(dBFS: -50.5, seconds: 2), sampleRate: Self.rate)
        #expect(over.hasSpeech)
        #expect(abs(over.speechSeconds - 2) < 0.001)
        #expect(!under.hasSpeech)
        #expect(under.speechSeconds == 0)
    }

    @Test("windows need not be contiguous: a few words across a quiet minute are speech")
    func scatteredWordsAreSpeech() {
        var samples: [Float] = []
        for _ in 0..<5 {
            samples += Self.silence(seconds: 11.8) + Self.tone(dBFS: -30, seconds: 0.2)
        }
        let level = RecordingSpeechLevel.measure(samples: samples, sampleRate: Self.rate)
        #expect(level.hasSpeech)
        #expect(abs(level.speechSeconds - 1.0) < 0.001)
    }

    // MARK: - Recordings on disk

    /// Write a recording as Zoom does, AAC at 48 kHz stereo, so a measurement
    /// also has to decode, resample and downmix. Each segment is a 440 Hz
    /// tone whose RMS is `dBFS`, or digital silence for nil.
    private static func writeRecording(_ segments: [(dBFS: Double?, seconds: Double)], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        var samples: [Float] = []
        for segment in segments {
            let count = Int((segment.seconds * format.sampleRate).rounded())
            guard let dBFS = segment.dBFS else {
                samples += [Float](repeating: 0, count: count)
                continue
            }
            let amplitude = sqrt(2) * pow(10, dBFS / 20)
            let start = samples.count
            samples += (0..<count).map {
                Float(amplitude * sin(2 * .pi * 440 * Double(start + $0) / format.sampleRate))
            }
        }
        let frames = AVAudioFrameCount(samples.count)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let destination = try #require(buffer.floatChannelData?[channel])
            samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
    }

    private static func temporaryRecording(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-level-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test("a silent recording on disk measures as no speech, read to its end")
    func silentFileHasNoSpeech() async throws {
        let url = Self.temporaryRecording("audio1047178209.m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.writeRecording([(-90, 64)], to: url)

        let level = try #require(await RecordingSpeechLevel.measure(mediaURL: url))
        #expect(!level.hasSpeech)
        #expect(level.measuredSeconds > 63)
        #expect(level.loudestWindowDBFS < -60)
    }

    @Test("a recording with speech on disk is heard, and read only as far as the speech")
    func spokenFileHasSpeech() async throws {
        let url = Self.temporaryRecording("audio2365865333.m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.writeRecording([(nil, 20), (-25, 3), (nil, 37)], to: url)

        let level = try #require(await RecordingSpeechLevel.measure(mediaURL: url))
        #expect(level.hasSpeech)
        #expect(level.measuredSeconds < 30)
    }

    @Test("a file that is not audio cannot be measured, which is not the same as silent")
    func unreadableFileIsUnmeasured() async throws {
        let url = Self.temporaryRecording("audio0.m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not a recording".utf8).write(to: url)

        #expect(await RecordingSpeechLevel.measure(mediaURL: url) == nil)
    }

    @Test("a recording with no speech fails transcription in words the session can show")
    func noSpeechReadsPlainly() {
        #expect(MeetingTranscriptionService.TranscriptionError.noSpeech.errorDescription == "The recording has no speech in it.")
    }
}
