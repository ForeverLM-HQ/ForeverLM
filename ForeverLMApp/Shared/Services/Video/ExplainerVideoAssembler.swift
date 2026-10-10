import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Joins a video explainer's clips into one MP4 and draws its poster, with
/// AVFoundation and nothing else: the clips come from one model at one
/// resolution, so a straight concatenation of their video and audio tracks is
/// the whole edit. Runs wherever it is awaited; nothing here touches the main
/// actor.
struct ExplainerVideoAssembler: ExplainerVideoAssembling {
    enum Failure: LocalizedError {
        case noClips
        case clipHasNoVideo(URL)
        case exportUnavailable
        case exportFailed(String)
        case posterFailed

        var errorDescription: String? {
            switch self {
            case .noClips: return "There are no clips to join."
            case .clipHasNoVideo(let url): return "\(url.lastPathComponent) has no video track."
            case .exportUnavailable: return "The film could not be exported on this Mac."
            case .exportFailed(let reason): return reason
            case .posterFailed: return "The poster frame could not be drawn."
            }
        }
    }

    /// Where the poster is taken from: a second in, past any fade the model
    /// opens on.
    static let posterTime = CMTime(seconds: 1, preferredTimescale: 600)

    func assemble(clips: [URL], into videoURL: URL, poster posterURL: URL) async throws -> Double {
        guard !clips.isEmpty else { throw Failure.noClips }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportUnavailable
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for (index, clipURL) in clips.enumerated() {
            let asset = AVURLAsset(url: clipURL)
            let duration = try await asset.load(.duration)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw Failure.clipHasNoVideo(clipURL)
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if index == 0 {
                videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
            }
            // A clip the model drew without a soundtrack leaves silence in its
            // slot rather than failing the film.
            if let audioTrack, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
            try Task.checkCancellation()
        }

        try? FileManager.default.removeItem(at: videoURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportUnavailable
        }
        export.outputURL = videoURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        switch export.status {
        case .completed:
            break
        case .cancelled:
            throw CancellationError()
        default:
            throw Failure.exportFailed(export.error?.localizedDescription ?? "The export did not finish.")
        }

        try await Self.writePoster(of: videoURL, to: posterURL)
        return cursor.seconds
    }

    /// One JPEG frame from the finished film, sized for a list card.
    static func writePoster(of videoURL: URL, to posterURL: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: posterTime)
        guard let destination = CGImageDestinationCreateWithURL(posterURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.posterFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.posterFailed }
    }
}


/// A video made elsewhere — a Gemini Notebook video overview, a lecture the
/// learner recorded — brought in as a source. It is filed the way a made
/// explainer video is (`GeneratedExplainerVideo`): a `video`-typed row at
/// `foreverlm://explainer-video/<id>`, its film and poster under the content
/// root's `Videos/<id>/`, so the Reader's player, search, sync, the Videos
/// pane and deletion take it with no second code path. It has no manifest: it
/// was not made by a storyboard, and the Reader draws a video without one.
///
/// The id is a hash of the file's bytes, not a fresh UUID, so importing the
/// same file again — from a second Mac, or twice — finds the row it already
/// made rather than a copy of it.
enum VideoOverviewImporter {
    enum Failure: LocalizedError, Equatable {
        case notAVideo(String)
        case noVideoTrack(String)
        case contentRootUnavailable
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAVideo(let name):
                return "\(name) is not a video ForeverLM can play (MP4, M4V or MOV)."
            case .noVideoTrack(let name):
                return "\(name) has no picture to play."
            case .contentRootUnavailable:
                return "The library folder could not be written to."
            case .copyFailed(let reason):
                return "The video could not be copied into the library: \(reason)"
            }
        }
    }

    /// What Gemini Notebook, QuickTime and a phone save a video as.
    static let fileExtensions: Set<String> = ["mp4", "m4v", "mov"]

    static func canImport(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// The row's title from the file's name: "Unlocking_SLC25A34_Switch.mp4"
    /// is "Unlocking SLC25A34 Switch". A name that is only separators falls
    /// back to the word the row would otherwise lack.
    static func title(forFileNamed name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let spaced = stem.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return spaced.isEmpty ? "Video overview" : spaced
    }

    /// The id the file's bytes name: the first 128 bits of their SHA-256, as
    /// the lowercase hex a `GeneratedExplainerVideo` id may be (no `/`).
    nonisolated static func videoID(hashing fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the file into `Videos/<id>/video.mp4`, draws its poster, and
    /// returns the source row (not yet saved). A file already imported leaves
    /// its folder as it is and returns the same row. Runs off the main actor;
    /// a failure removes whatever folder this call made.
    nonisolated static func importFile(at fileURL: URL, contentRootPath: String) async throws -> StudioArticle {
        let name = fileURL.lastPathComponent
        guard canImport(fileURL) else { throw Failure.notAVideo(name) }
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

        let videoID = try await Task.detached(priority: .userInitiated) {
            try VideoOverviewImporter.videoID(hashing: fileURL)
        }.value
        let root = URL(fileURLWithPath: contentRootPath, isDirectory: true)
        let directory = root.appendingPathComponent(GeneratedExplainerVideo.relativeDirectory(videoID: videoID), isDirectory: true)
        let videoURL = directory.appendingPathComponent("video.mp4")
        let posterURL = directory.appendingPathComponent("poster.jpg")
        let manager = FileManager.default

        let madeDirectory = !manager.fileExists(atPath: directory.path)
        if !manager.fileExists(atPath: videoURL.path) {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw Failure.contentRootUnavailable
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: fileURL, to: videoURL)
                }.value
            } catch {
                if madeDirectory { try? manager.removeItem(at: directory) }
                throw Failure.copyFailed(error.localizedDescription)
            }
        }

        do {
            let asset = AVURLAsset(url: videoURL)
            guard try await asset.loadTracks(withMediaType: .video).first != nil else {
                throw Failure.noVideoTrack(name)
            }
            if !manager.fileExists(atPath: posterURL.path) {
                do {
                    try await ExplainerVideoAssembler.writePoster(of: videoURL, to: posterURL)
                } catch {
                    // A film shorter than the poster's second has no frame
                    // there; the row is still worth keeping without one.
                    try? manager.removeItem(at: posterURL)
                }
            }
        } catch {
            if madeDirectory { try? manager.removeItem(at: directory) }
            throw error is Failure ? error : Failure.notAVideo(name)
        }

        var video = StudioArticle(
            url: GeneratedExplainerVideo.url(videoID: videoID),
            title: title(forFileNamed: name),
            sourceType: .video,
            artworkURL: manager.fileExists(atPath: posterURL.path)
                ? GeneratedExplainerVideo.relativePosterPath(videoID: videoID)
                : nil,
            discoveryOrigin: .manual,
            localFilePath: GeneratedExplainerVideo.relativeVideoPath(videoID: videoID)
        )
        video.domain = GeneratedExplainerVideo.domain
        video.state = .ready
        return video
    }
}
