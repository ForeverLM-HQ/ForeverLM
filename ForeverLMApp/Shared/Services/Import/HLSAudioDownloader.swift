import CommonCrypto
import Foundation

/// Downloads the audio of an HTTP Live Streaming presentation into one local
/// file that AVFoundation can read, so `MeetingTranscriptionService` can
/// transcribe it.
///
/// `AVAssetExportSession` cannot export a remote HLS stream, and a course
/// platform's player only ever hands out a playlist, never a file. So this
/// reads the playlist itself: it picks the smallest rendition that carries
/// audio (an audio-only rendition when the master lists one), downloads its
/// segments in order, decrypts AES-128 segments with the key the playlist
/// names, and writes the audio out:
///
/// - MPEG-TS segments are demultiplexed to their ADTS AAC (`.aac`) or MPEG
///   audio (`.mp3`) elementary stream, which is all a transcript needs and a
///   fraction of the video's size.
/// - Fragmented MP4 segments are written after their `EXT-X-MAP` header as one
///   `.mp4`.
/// - Packed audio segments (`.aac` with an ID3 timestamp tag) are joined with
///   the tags stripped.
///
/// `SAMPLE-AES` and other key methods are DRM, and are refused rather than
/// worked around. Nothing here is specific to one platform: the resolver for
/// a platform (`TeachableCourseService` for Hotmart) finds the playlist and
/// the headers its CDN wants, and this does the rest.
enum HLSAudioDownloader {
    enum HLSError: LocalizedError, Equatable {
        case notAPlaylist
        case noAudioRendition
        case unsupportedEncryption(String)
        case byteRangeSegmentsUnsupported
        case keyUnavailable(String)
        case segmentFailed(index: Int, detail: String)
        case unsupportedSegmentFormat
        case noAudioTrack
        case emptyStream

        var errorDescription: String? {
            switch self {
            case .notAPlaylist:
                return "The video's stream address did not return an HLS playlist."
            case .noAudioRendition:
                return "The video's stream lists no rendition with audio."
            case .unsupportedEncryption(let method):
                return "The video is protected with \(method), which ForeverLM does not open."
            case .byteRangeSegmentsUnsupported:
                return "The video's stream uses byte-range segments, which ForeverLM does not read yet."
            case .keyUnavailable(let detail):
                return "The video's decryption key could not be fetched: \(detail)"
            case .segmentFailed(let index, let detail):
                return "Segment \(index + 1) of the video could not be downloaded: \(detail)"
            case .unsupportedSegmentFormat:
                return "The video's stream segments are in a format ForeverLM does not read."
            case .noAudioTrack:
                return "The video's stream carries no audio track ForeverLM can read."
            case .emptyStream:
                return "The video's stream contained no audio."
            }
        }
    }

    // MARK: - Playlist model

    struct Variant: Equatable {
        let uri: URL
        let bandwidth: Int
        let codecs: String?
        let audioGroup: String?
    }

    struct AudioRendition: Equatable {
        let uri: URL
        let groupID: String?
        let isDefault: Bool
    }

    struct MasterPlaylist: Equatable {
        let variants: [Variant]
        let audioRenditions: [AudioRendition]

        /// The playlist whose segments carry audio for the fewest bytes: an
        /// audio-only rendition when there is one (the default first), else the
        /// lowest-bandwidth variant whose codecs include audio. A variant that
        /// names no codecs is taken to carry its audio, as HLS allows.
        func audioPlaylistURL() -> URL? {
            if let rendition = audioRenditions.first(where: \.isDefault) ?? audioRenditions.first {
                return rendition.uri
            }
            let withAudio = variants.filter { variant in
                guard let codecs = variant.codecs?.lowercased() else { return true }
                return codecs.contains("mp4a") || codecs.contains("ac-3") || codecs.contains("ec-3")
                    || codecs.contains("mp3") || codecs.contains("opus")
            }
            return withAudio.min(by: { $0.bandwidth < $1.bandwidth })?.uri
        }
    }

    enum KeyMethod: Equatable {
        case none
        case aes128(uri: URL, iv: Data?)
    }

    struct Segment: Equatable {
        let uri: URL
        let sequenceNumber: Int
        let key: KeyMethod
    }

    struct MediaPlaylist: Equatable {
        let segments: [Segment]
        /// The `EXT-X-MAP` initialization section of a fragmented MP4 stream.
        let initializationSection: URL?
    }

    enum Playlist: Equatable {
        case master(MasterPlaylist)
        case media(MediaPlaylist)
    }

    // MARK: - Download

    /// Download `playlistURL`'s audio into `directory` and return the file.
    /// `headers` go on every request (a CDN may want a Referer on the
    /// playlist). `progress` reports finished and total segments.
    static func downloadAudio(
        from playlistURL: URL,
        into directory: URL,
        headers: [String: String] = [:],
        session: URLSession = .shared,
        progress: (@Sendable (_ finished: Int, _ total: Int) -> Void)? = nil
    ) async throws -> URL {
        var mediaURL = playlistURL
        var text = try await fetchText(playlistURL, headers: headers, session: session)
        var playlist = try parse(text, baseURL: mediaURL)
        if case .master(let master) = playlist {
            guard let audioURL = master.audioPlaylistURL() else { throw HLSError.noAudioRendition }
            mediaURL = audioURL
            text = try await fetchText(audioURL, headers: headers, session: session)
            playlist = try parse(text, baseURL: audioURL)
        }
        guard case .media(let media) = playlist else { throw HLSError.noAudioRendition }
        guard !media.segments.isEmpty else { throw HLSError.emptyStream }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keys: [URL: Data] = [:]
        var writer = AudioStreamWriter()
        if let map = media.initializationSection {
            writer.initializationSection = try await fetchData(map, headers: headers, session: session)
        }

        // A few segments in flight at once, written strictly in order.
        let window = 6
        let total = media.segments.count
        var next = 0
        while next < total {
            let batch = Array(media.segments[next..<min(next + window, total)])
            for segment in batch {
                if case .aes128(let keyURL, _) = segment.key, keys[keyURL] == nil {
                    do {
                        let key = try await fetchData(keyURL, headers: headers, session: session)
                        guard key.count == kCCKeySizeAES128 else {
                            throw HLSError.keyUnavailable("the key is \(key.count) bytes, not 16")
                        }
                        keys[keyURL] = key
                    } catch let error as HLSError {
                        throw error
                    } catch {
                        throw HLSError.keyUnavailable(error.localizedDescription)
                    }
                }
            }
            let bodies = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (offset, segment) in batch.enumerated() {
                    let index = next + offset
                    group.addTask {
                        let body = try await fetchSegment(segment, index: index, headers: headers, session: session)
                        return (offset, body)
                    }
                }
                var ordered = [Data?](repeating: nil, count: batch.count)
                for try await (offset, body) in group {
                    ordered[offset] = body
                }
                return ordered.compactMap { $0 }
            }
            for (offset, body) in bodies.enumerated() {
                let segment = batch[offset]
                let clear: Data
                if case .aes128(let keyURL, let iv) = segment.key, let key = keys[keyURL] {
                    clear = try decryptAES128(body, key: key, iv: iv ?? sequenceIV(segment.sequenceNumber))
                } else {
                    clear = body
                }
                try writer.append(clear)
            }
            next += batch.count
            progress?(next, total)
        }

        let (data, fileExtension) = try writer.finish()
        let output = directory.appendingPathComponent("stream-audio.\(fileExtension)")
        try? FileManager.default.removeItem(at: output)
        try data.write(to: output)
        return output
    }

    private static func fetchSegment(
        _ segment: Segment,
        index: Int,
        headers: [String: String],
        session: URLSession
    ) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await fetchData(segment.uri, headers: headers, session: session)
            } catch {
                lastError = error
                if attempt < 2 { try await Task.sleep(for: .milliseconds(400 * (attempt + 1))) }
            }
        }
        throw HLSError.segmentFailed(index: index, detail: lastError?.localizedDescription ?? "unknown error")
    }

    private static func fetchText(_ url: URL, headers: [String: String], session: URLSession) async throws -> String {
        let data = try await fetchData(url, headers: headers, session: session)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw HLSError.notAPlaylist
        }
        return text
    }

    private static func fetchData(_ url: URL, headers: [String: String], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(url.host ?? "the server")"
            ])
        }
        return data
    }

    // MARK: - Parsing

    static func parse(_ text: String, baseURL: URL) throws -> Playlist {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { throw HLSError.notAPlaylist }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            var variants: [Variant] = []
            var renditions: [AudioRendition] = []
            var pendingInfo: [String: String]?
            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    pendingInfo = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                } else if line.hasPrefix("#EXT-X-MEDIA:") {
                    let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                    if attrs["TYPE"] == "AUDIO",
                       let uri = attrs["URI"],
                       let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                        renditions.append(AudioRendition(
                            uri: url,
                            groupID: attrs["GROUP-ID"],
                            isDefault: attrs["DEFAULT"] == "YES"
                        ))
                    }
                } else if let info = pendingInfo, !line.isEmpty, !line.hasPrefix("#") {
                    if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                        variants.append(Variant(
                            uri: url,
                            bandwidth: Int(info["BANDWIDTH"] ?? "") ?? Int.max,
                            codecs: info["CODECS"],
                            audioGroup: info["AUDIO"]
                        ))
                    }
                    pendingInfo = nil
                }
            }
            return .master(MasterPlaylist(variants: variants, audioRenditions: renditions))
        }

        var segments: [Segment] = []
        var sequence = 0
        var key = KeyMethod.none
        var map: URL?
        var expectingURI = false
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"] ?? "NONE"
                switch method {
                case "NONE":
                    key = .none
                case "AES-128":
                    guard let uri = attrs["URI"],
                          let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
                        throw HLSError.keyUnavailable("the playlist names no key address")
                    }
                    key = .aes128(uri: url, iv: attrs["IV"].flatMap(hexData))
                default:
                    throw HLSError.unsupportedEncryption(method)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if attrs["BYTERANGE"] != nil { throw HLSError.byteRangeSegmentsUnsupported }
                map = attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                throw HLSError.byteRangeSegmentsUnsupported
            } else if line.hasPrefix("#EXTINF:") {
                expectingURI = true
            } else if expectingURI, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    segments.append(Segment(uri: url, sequenceNumber: sequence, key: key))
                }
                sequence += 1
                expectingURI = false
            }
        }
        return .media(MediaPlaylist(segments: segments, initializationSection: map))
    }

    /// An HLS attribute list: `KEY=value,KEY="quoted, value"`.
    static func attributes(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        func commit() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""
            value = ""
            readingKey = true
        }
        for character in list {
            if readingKey {
                if character == "=" { readingKey = false } else { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }

    private static func hexData(_ hex: String) -> Data? {
        var digits = hex.lowercased()
        if digits.hasPrefix("0x") { digits.removeFirst(2) }
        guard digits.count == 32 else { return nil }
        var data = Data(capacity: 16)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - Decryption

    /// The IV a segment gets when its key names none: its media sequence
    /// number as a 128-bit big-endian integer (RFC 8216 §5.2).
    static func sequenceIV(_ sequenceNumber: Int) -> Data {
        var iv = Data(count: 16)
        var number = UInt64(max(0, sequenceNumber)).bigEndian
        withUnsafeBytes(of: &number) { bytes in
            iv.replaceSubrange(8..<16, with: bytes)
        }
        return iv
    }

    static func decryptAES128(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            input.baseAddress, data.count,
                            out.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw HLSError.keyUnavailable("the segment did not decrypt with the stream's key (status \(status))")
        }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

// MARK: - Writing the audio

/// Accumulates decrypted segments into one audio file's bytes.
struct AudioStreamWriter {
    enum Kind { case transportStream, fragmentedMP4, packedAudio }

    var initializationSection: Data?
    private var kind: Kind?
    private var demuxer = MPEGTSAudioDemuxer()
    private var body = Data()

    mutating func append(_ segment: Data) throws {
        let segmentKind = try kind ?? Self.detect(segment, hasMap: initializationSection != nil)
        kind = segmentKind
        switch segmentKind {
        case .transportStream:
            try demuxer.consume(segment)
        case .fragmentedMP4:
            if body.isEmpty, let initializationSection { body.append(initializationSection) }
            body.append(segment)
        case .packedAudio:
            body.append(Self.strippingID3(segment))
        }
    }

    mutating func finish() throws -> (Data, String) {
        switch kind {
        case .transportStream:
            let (audio, fileExtension) = try demuxer.finish()
            guard !audio.isEmpty else { throw HLSAudioDownloader.HLSError.emptyStream }
            return (audio, fileExtension)
        case .fragmentedMP4:
            return (body, "mp4")
        case .packedAudio:
            guard !body.isEmpty else { throw HLSAudioDownloader.HLSError.emptyStream }
            return (body, "aac")
        case nil:
            throw HLSAudioDownloader.HLSError.emptyStream
        }
    }

    static func detect(_ segment: Data, hasMap: Bool) throws -> Kind {
        let bytes = [UInt8](segment.prefix(4))
        if bytes.first == 0x47, segment.count >= 188 { return .transportStream }
        if hasMap { return .fragmentedMP4 }
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return .packedAudio }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0 { return .packedAudio }
        throw HLSAudioDownloader.HLSError.unsupportedSegmentFormat
    }

    /// Drop a leading ID3v2 tag (packed audio carries its timestamp in one).
    static func strippingID3(_ data: Data) -> Data {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return data }
        let size = (Int(bytes[6] & 0x7F) << 21) | (Int(bytes[7] & 0x7F) << 14)
            | (Int(bytes[8] & 0x7F) << 7) | Int(bytes[9] & 0x7F)
        let footer = bytes[5] & 0x10 != 0 ? 10 : 0
        let start = 10 + size + footer
        guard start < data.count else { return Data() }
        return data.subdata(in: data.startIndex + start..<data.endIndex)
    }
}

/// Pulls the first audio elementary stream out of MPEG transport stream
/// packets (ISO/IEC 13818-1): PAT → PMT → the audio PID's PES payloads.
struct MPEGTSAudioDemuxer {
    private static let packetSize = 188
    private var pmtPID: Int?
    private var audioPID: Int?
    private var audioStreamType: UInt8?
    private var pes = Data()
    private var output = Data()
    private var carry = Data()

    mutating func consume(_ data: Data) throws {
        var buffer = carry
        buffer.append(data)
        carry = Data()
        let bytes = [UInt8](buffer)
        var offset = 0
        // Resynchronise on the sync byte if a segment starts mid-packet.
        while offset < bytes.count, bytes[offset] != 0x47 { offset += 1 }
        while offset + Self.packetSize <= bytes.count {
            guard bytes[offset] == 0x47 else {
                offset += 1
                continue
            }
            handlePacket(bytes, at: offset)
            offset += Self.packetSize
        }
        if offset < bytes.count {
            carry = Data(bytes[offset...])
        }
    }

    mutating func finish() throws -> (Data, String) {
        flushPES()
        guard let type = audioStreamType else { throw HLSAudioDownloader.HLSError.noAudioTrack }
        return (output, type == 0x0F ? "aac" : "mp3")
    }

    private mutating func handlePacket(_ bytes: [UInt8], at start: Int) {
        let payloadUnitStart = bytes[start + 1] & 0x40 != 0
        let pid = (Int(bytes[start + 1] & 0x1F) << 8) | Int(bytes[start + 2])
        let adaptation = (bytes[start + 3] >> 4) & 0x03
        var payload = start + 4
        if adaptation == 0x02 || adaptation == 0x03 {
            payload += 1 + Int(bytes[start + 4])
        }
        let end = start + Self.packetSize
        guard adaptation != 0x02, payload < end else { return }

        if pid == 0 {
            parsePAT(Array(bytes[payload..<end]), payloadUnitStart: payloadUnitStart)
        } else if pid == pmtPID {
            parsePMT(Array(bytes[payload..<end]), payloadUnitStart: payloadUnitStart)
        } else if pid == audioPID {
            if payloadUnitStart { flushPES() }
            pes.append(contentsOf: bytes[payload..<end])
        }
    }

    private static func section(_ payload: [UInt8], payloadUnitStart: Bool) -> [UInt8]? {
        guard payloadUnitStart, let pointer = payload.first else { return nil }
        let start = 1 + Int(pointer)
        guard start + 3 <= payload.count else { return nil }
        let length = (Int(payload[start + 1] & 0x0F) << 8) | Int(payload[start + 2])
        let end = min(payload.count, start + 3 + length)
        return Array(payload[start..<end])
    }

    private mutating func parsePAT(_ payload: [UInt8], payloadUnitStart: Bool) {
        guard pmtPID == nil, let table = Self.section(payload, payloadUnitStart: payloadUnitStart),
              table.first == 0x00, table.count >= 12 else { return }
        var index = 8
        while index + 4 <= table.count - 4 {
            let program = (Int(table[index]) << 8) | Int(table[index + 1])
            let pid = (Int(table[index + 2] & 0x1F) << 8) | Int(table[index + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            index += 4
        }
    }

    private mutating func parsePMT(_ payload: [UInt8], payloadUnitStart: Bool) {
        guard audioPID == nil, let table = Self.section(payload, payloadUnitStart: payloadUnitStart),
              table.first == 0x02, table.count >= 16 else { return }
        let programInfoLength = (Int(table[10] & 0x0F) << 8) | Int(table[11])
        var index = 12 + programInfoLength
        var mpegAudio: (pid: Int, type: UInt8)?
        while index + 5 <= table.count - 4 {
            let type = table[index]
            let pid = (Int(table[index + 1] & 0x1F) << 8) | Int(table[index + 2])
            let infoLength = (Int(table[index + 3] & 0x0F) << 8) | Int(table[index + 4])
            if type == 0x0F {
                audioPID = pid
                audioStreamType = type
                return
            }
            if (type == 0x03 || type == 0x04), mpegAudio == nil { mpegAudio = (pid, type) }
            index += 5 + infoLength
        }
        if let mpegAudio {
            audioPID = mpegAudio.pid
            audioStreamType = mpegAudio.type
        }
    }

    /// Strip the PES header and keep the elementary stream bytes.
    private mutating func flushPES() {
        defer { pes = Data() }
        let bytes = [UInt8](pes)
        guard bytes.count >= 9, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01 else { return }
        let headerLength = Int(bytes[8])
        let start = 9 + headerLength
        guard start < bytes.count else { return }
        output.append(contentsOf: bytes[start...])
    }
}
