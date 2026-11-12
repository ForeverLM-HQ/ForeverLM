import AppKit
import AVFoundation
import Foundation
import OSLog

/// Gives a meeting session a picture, from the cheapest source that has one.
///
/// A meeting row falls back to an SF Symbol because nothing in the import ever
/// gave it artwork, and the three ways to fix that are not equal. Two are free
/// and show what the meeting actually looked like — the thumbnail Drive already
/// made for the recording, and a frame decoded from the recording itself. The
/// third draws something from what the meeting was *about*, and costs money
/// every time. So they are tried in that order, and only the free two ever run
/// without being asked for.
///
/// The result is one small JPEG under the library root, referenced by the
/// relative path convention the rest of the app uses, so it survives a move
/// between content roots. It reaches another Mac as `meetingIconAsset` on the
/// source's CloudKit record. Source content is local, so nothing else carries the
/// picture: syncing the path alone would leave meetings on the receiving Mac
/// showing a glyph beside a path to a file they had never been sent.
actor MeetingIconService {
    static let shared = MeetingIconService()

    /// Which of the three sources produced an icon. Worth reporting because
    /// only one of them spends money.
    enum Origin: String, Sendable {
        case driveThumbnail
        case recordingFrame
        case generated
    }

    struct Outcome: Sendable {
        /// Path relative to the content root, for `StudioArticle.artworkURL`.
        let relativePath: String
        let origin: Origin
        /// Whether this run put the file on disk, as opposed to finding one
        /// already there. The caller needs the difference: an icon newly written
        /// at a path the source already records still has to be saved, or the
        /// record never changes and the picture never leaves this Mac.
        let wroteFile: Bool
    }

    /// Everything the service needs about one session, snapshotted on the main
    /// actor by the caller so nothing here reaches back into the view model.
    struct Request: Sendable {
        let sourceID: String
        let title: String
        let presenter: String?
        let groupTitle: String?
        /// Drive URL or file id of the session's recording, when it has one.
        let recordingURLOrID: String?
        let recordingMIMEType: String?
        let recordingModifiedAt: Date?
        /// A recording sitting on this Mac already — a local meeting folder, or
        /// a Drive file some earlier playback or transcription cached.
        let localRecordingPath: String?
        /// Whether this call may fall through to a paid model. The free sources
        /// are always allowed.
        let allowsGeneration: Bool
        /// Which source the learner asked for. Only meaningful alongside
        /// `allowsGeneration`: with nothing paid available, a frame is the only
        /// picture on offer whatever the preference says.
        let source: ImageGenerationCatalog.Source
    }

    /// Icons are square and displayed at 42 points; 256 is the largest size a
    /// Retina sidebar can show, and small enough that forty of them cost less
    /// disk than one recording.
    private static let storedPixelSize = 256

    private let logger = Logger(subsystem: "com.foreverlm", category: "MeetingIcons")

    // MARK: - Location

    /// The file name records where the picture came from, because the learner
    /// can change their mind. Someone who switches to Always Draw is asking for
    /// the caught frames to be replaced, and a single `icon.jpg` could not say
    /// which of the icons on disk were frames.
    ///
    /// `icon.jpg` is the captured name for compatibility: every icon written
    /// before this distinction existed was a frame or a Drive thumbnail.
    nonisolated static func relativePath(sourceID: String, drawn: Bool = false) -> String {
        "Meetings/\(sourceID)/\(drawn ? "icon-drawn.jpg" : "icon.jpg")"
    }

    nonisolated static func absolutePath(sourceID: String, drawn: Bool = false) -> String {
        StorageService.absoluteSourcePath(relativePath(sourceID: sourceID, drawn: drawn))
    }

    /// Whether a stored icon was drawn rather than captured, read from the path
    /// the source already carries.
    nonisolated static func isDrawnIconPath(_ artworkURL: String?) -> Bool {
        guard let raw = artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return raw.hasSuffix("icon-drawn.jpg")
    }

    /// The absolute path behind an `artworkURL` that names a stored file rather
    /// than a remote image, or nil when it names a URL.
    ///
    /// Podcast covers and YouTube stills live at `https://…` and load over the
    /// network; a generated or captured icon is content this app wrote, stored
    /// the way every other source file is — relative to the content root, so it
    /// survives the library moving between iCloud and local storage.
    nonisolated static func localArtworkPath(for artworkURL: String?) -> String? {
        guard let raw = artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.lowercased().hasPrefix("http") else { return nil }
        // Tried against every content root first: a poster written under the
        // synced root (a video explainer's) is found there, and a path with no
        // file behind it still resolves to where the local root would put it.
        return StorageService.locateSourceFile(raw) ?? StorageService.absoluteSourcePath(raw)
    }

    /// Whether a stored icon path still has a file behind it on this Mac.
    ///
    /// A path is not a picture. `artwork_url` reaches the other Mac through the
    /// ordinary record sync and the JPEG travels separately, so a Mac routinely
    /// holds the path to an icon whose bytes have not arrived — and the only way
    /// to tell is to stat it.
    ///
    /// Cached because the caller is a count over the whole library, read inside
    /// a Settings view body: hundreds of stats per render pass is the shape of
    /// I/O that has beachballed this app before. Nothing but this app creates
    /// these files, and both places that do call `noteStoredIconChanged`, so a
    /// cached answer cannot go stale behind our back.
    ///
    /// Resolved against the current content root only, exactly like the row that
    /// draws it. A multi-root lookup would answer "present" for a file the
    /// renderer cannot find, which is the very disagreement this exists to end.
    nonisolated static func hasStoredIconFile(forArtworkURL artworkURL: String?) -> Bool {
        guard let absolutePath = localArtworkPath(for: artworkURL) else { return false }
        storedIconExistenceLock.lock()
        defer { storedIconExistenceLock.unlock() }
        if let cached = storedIconExistence[absolutePath] { return cached }
        let exists = FileManager.default.isReadableFile(atPath: absolutePath)
        storedIconExistence[absolutePath] = exists
        return exists
    }

    /// Forget the cached answer for one icon. Called wherever this app writes an
    /// icon — a capture, a drawing, or an inbound asset installed by sync.
    ///
    /// The picture almost always lands at a path some row has already drawn as a
    /// placeholder, which leaves that row's thumbnail cache key unchanged and
    /// nothing to make it look again. The same broadcast book covers use is why
    /// a recovered icon appears without relaunching the app.
    nonisolated static func noteStoredIconChanged(absolutePath: String) {
        storedIconExistenceLock.lock()
        storedIconExistence.removeValue(forKey: absolutePath)
        storedIconExistenceLock.unlock()
        NotificationCenter.default.post(name: .syncedArtworkDidInstall, object: nil)
    }

    private static let storedIconExistenceLock = AppLock()
    nonisolated(unsafe) private static var storedIconExistence: [String: Bool] = [:]

    /// A stored icon that already satisfies the learner's preference, or nil.
    ///
    /// Under Always Draw a captured frame does not count, which is what makes
    /// switching to it redraw the sidebar instead of leaving the frames that
    /// prompted the switch. The reverse is not true: a drawn icon satisfies
    /// Prefer a Real Thumbnail, because that preference is about what to spend
    /// on next, not a reason to throw away a picture already paid for.
    nonisolated static func existingRelativePath(
        sourceID: String,
        source: ImageGenerationCatalog.Source = .preferThumbnail
    ) -> String? {
        for drawn in [true, false] {
            if !drawn, source.drawsEverything { continue }
            let relative = relativePath(sourceID: sourceID, drawn: drawn)
            if FileManager.default.fileExists(atPath: StorageService.absoluteSourcePath(relative)) {
                return relative
            }
        }
        return nil
    }

    // MARK: - Resolution

    /// Free sources first, then the paid one when the request allows it.
    /// Returns nil when nothing produced a picture, which is not an error: a
    /// notes-only session with generation off simply keeps its glyph.
    func icon(for request: Request) async -> Outcome? {
        if let existing = Self.existingRelativePath(sourceID: request.sourceID, source: request.source) {
            return Outcome(
                relativePath: existing,
                origin: Self.isDrawnIconPath(existing) ? .generated : .driveThumbnail,
                wroteFile: false
            )
        }

        // Always Draw goes to the model first. Falling back to a frame when the
        // model refuses is deliberate: a picture the learner did not ask for
        // still beats the glyph they were trying to get rid of, and the next
        // run will try to draw it again.
        if request.source.drawsEverything, request.allowsGeneration,
           let drawn = await drawIcon(for: request) {
            return drawn
        }

        if let recordingURLOrID = request.recordingURLOrID {
            if let image = await driveThumbnail(
                fileURLOrID: recordingURLOrID,
                sourceID: request.sourceID
            ), let stored = store(image, sourceID: request.sourceID) {
                return Outcome(relativePath: stored, origin: .driveThumbnail, wroteFile: true)
            }
            if let image = await recordingFrame(
                fileURLOrID: recordingURLOrID,
                localPath: request.localRecordingPath,
                mimeType: request.recordingMIMEType,
                modifiedAt: request.recordingModifiedAt
            ), let stored = store(image, sourceID: request.sourceID) {
                return Outcome(relativePath: stored, origin: .recordingFrame, wroteFile: true)
            }
        }

        guard request.allowsGeneration else { return nil }
        return await drawIcon(for: request)
    }

    private func drawIcon(for request: Request) async -> Outcome? {
        do {
            let image = try await generate(for: request)
            guard let stored = store(image, sourceID: request.sourceID, drawn: true) else { return nil }
            return Outcome(relativePath: stored, origin: .generated, wroteFile: true)
        } catch {
            logger.warning("Meeting icon generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Free sources

    /// The thumbnail Drive already rendered for the recording. Costs one
    /// authenticated request and shows a real frame of the meeting.
    private func driveThumbnail(fileURLOrID: String, sourceID: String) async -> NSImage? {
        do {
            guard let data = try await GoogleDriveService.shared.thumbnailData(fileURLOrID: fileURLOrID) else {
                return nil
            }
            return NSImage(data: data)
        } catch {
            logger.debug("No Drive thumbnail for \(sourceID, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    /// A frame decoded from the recording itself, for a file Drive made no
    /// thumbnail for. Sampled a quarter of the way in: meetings open on a
    /// title card or an empty room, and the opening seconds are the least
    /// representative part of the whole recording.
    ///
    /// Only ever reads a recording that is already on this Mac. Downloading one
    /// would make a 42-point icon cost a gigabyte of video, and a backfill
    /// across a whole library dozens of them.
    private func recordingFrame(
        fileURLOrID: String,
        localPath: String?,
        mimeType: String?,
        modifiedAt: Date?
    ) async -> NSImage? {
        guard let mediaURL = await Self.localMediaURL(
            fileURLOrID: fileURLOrID,
            localPath: localPath,
            mimeType: mimeType,
            modifiedAt: modifiedAt
        ) else { return nil }
        do {
            let asset = AVURLAsset(url: mediaURL)
            guard let duration = try? await asset.load(.duration),
                  duration.isNumeric,
                  duration.seconds > 0 else { return nil }
            // An audio-only recording is a normal thing for a meeting to be.
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard !videoTracks.isEmpty else { return nil }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: Self.storedPixelSize * 2,
                height: Self.storedPixelSize * 2
            )
            // A frame only has to look like the meeting, so letting the decoder
            // settle on a nearby keyframe beats decoding forward to an exact one.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let time = CMTime(seconds: duration.seconds * 0.25, preferredTimescale: 600)
            let (frame, _) = try await generator.image(at: time)
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        } catch {
            logger.debug("No recording frame: \(error.localizedDescription)")
            return nil
        }
    }

    private static func localMediaURL(
        fileURLOrID: String,
        localPath: String?,
        mimeType: String?,
        modifiedAt: Date?
    ) async -> URL? {
        if let localPath {
            let resolved = StorageService.absoluteSourcePath(localPath)
            if FileManager.default.fileExists(atPath: resolved) {
                return URL(fileURLWithPath: resolved)
            }
        }
        return await GoogleDriveService.shared.existingCachedRecordingURL(
            fileURLOrID: fileURLOrID,
            mimeType: mimeType,
            modifiedAt: modifiedAt
        )
    }

    // MARK: - Generation

    /// Draws the icon through the shared managed image path. Low quality at a
    /// square 1024 is the cheapest thing either maker will draw, and the
    /// picture is displayed at 42 points.
    private func generate(for request: Request) async throws -> NSImage {
        let model = await MainActor.run { MacImageGenerationSettings.model }
        let style = await MainActor.run { MacImageGenerationSettings.style }
        let prompt = ImageGenerationCatalog.iconPrompt(
            topic: request.title,
            presenter: request.presenter,
            groupTitle: request.groupTitle,
            style: style
        )
        let generated = try await ManagedImageGeneration.generate(
            prompt: prompt,
            model: model,
            shape: .square,
            quality: .low,
            usageTask: "meeting_icon",
            source: AIUsageSource(id: request.sourceID, type: "meeting", title: request.title)
        )
        guard let image = NSImage(data: generated.data) else {
            throw ManagedImageGeneration.Failure.noImageReturned
        }
        return image
    }

    // MARK: - Storage

    /// Square-crops, downsizes, and writes the icon beside the session's other
    /// content. Returns the relative path to store, or nil if it could not be
    /// encoded — in which case the row keeps its glyph rather than a broken
    /// reference.
    private func store(_ image: NSImage, sourceID: String, drawn: Bool = false) -> String? {
        guard let squared = Self.squareThumbnail(image, pixels: Self.storedPixelSize),
              let data = NSBitmapImageRep(cgImage: squared)
                  .representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            return nil
        }
        let destination = URL(fileURLWithPath: Self.absolutePath(sourceID: sourceID, drawn: drawn))
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            Self.noteStoredIconChanged(absolutePath: destination.path)
        } catch {
            logger.error("Could not write meeting icon: \(error.localizedDescription)")
            return nil
        }
        return Self.relativePath(sourceID: sourceID, drawn: drawn)
    }

    /// Centre-crops to a square and scales to `pixels`. A 16:9 meeting frame
    /// cropped from the centre keeps the speaker and the slide; scaled without
    /// cropping it would letterbox into a stripe inside a square row.
    nonisolated static func squareThumbnail(_ image: NSImage, pixels: Int) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let side = min(source.width, source.height)
        let cropped = source.cropping(to: CGRect(
            x: (source.width - side) / 2,
            y: (source.height - side) / 2,
            width: side,
            height: side
        )) ?? source

        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
    }
}
