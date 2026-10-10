import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns whatever picture the learner dropped into bytes every vision route
/// takes: one of four media types, at most `maxPixelSize` on its long edge,
/// under `maxByteCount`.
///
/// The limits are the providers': Anthropic reads up to 5 MB and downsizes
/// past roughly 1568 pixels itself, OpenAI and Gemini read PNG, JPEG, GIF and
/// WebP, and none of them read HEIC or TIFF, which is what a screenshot or a
/// photo from the camera roll arrives as. A picture already inside every limit
/// is kept byte for byte — the model sees exactly what the learner saw —
/// and anything else is re-encoded once, here, before it is stored, so the
/// bytes on disk are the bytes every later turn sends.
enum ChatImagePreparation {
    /// The long edge a re-encoded picture is scaled to. Anthropic's documented
    /// sweet spot; more pixels cost tokens without adding legibility.
    static let maxPixelSize = 1568
    /// Kept under Anthropic's 5 MB per-image limit with room for base64.
    static let maxByteCount = 3_500_000
    static let acceptedMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    struct Prepared: Equatable, Sendable {
        let image: AttachedImage
        let pixelWidth: Int
        let pixelHeight: Int
    }

    enum Failure: LocalizedError, Equatable {
        case notAnImage
        case couldNotEncode

        var errorDescription: String? {
            switch self {
            case .notAnImage:
                return "That file is not a picture ForeverLM can read."
            case .couldNotEncode:
                return "The picture could not be converted for the chat."
            }
        }
    }

    /// Never called on the main actor: decoding a photo takes real time.
    static func prepare(_ data: Data) throws -> Prepared {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure.notAnImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let mediaType = (CGImageSourceGetType(source) as String?)
            .flatMap { UTType($0) }?
            .preferredMIMEType?
            .lowercased()

        var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // A rotated photo reports its stored dimensions; the thumbnail below
        // applies the orientation, and so does every viewer of the kept bytes.
        if let orientation = properties?[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&width, &height)
        }

        if let mediaType, acceptedMediaTypes.contains(mediaType),
           width > 0, height > 0,
           max(width, height) <= maxPixelSize,
           data.count <= maxByteCount {
            return Prepared(
                image: AttachedImage(data: data, mediaType: mediaType),
                pixelWidth: width,
                pixelHeight: height
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.notAnImage
        }

        // A transparent picture (a diagram cut out of a slide) keeps its
        // transparency as PNG unless that alone busts the size limit; a photo
        // has nothing to keep and goes straight to JPEG.
        if hasAlpha(image),
           let png = encode(image, as: .png, quality: nil),
           png.count <= maxByteCount {
            return Prepared(
                image: AttachedImage(data: png, mediaType: "image/png"),
                pixelWidth: image.width,
                pixelHeight: image.height
            )
        }
        for quality in [0.85, 0.7, 0.5] {
            guard let jpeg = encode(image, as: .jpeg, quality: quality) else { continue }
            if jpeg.count <= maxByteCount {
                return Prepared(
                    image: AttachedImage(data: jpeg, mediaType: "image/jpeg"),
                    pixelWidth: image.width,
                    pixelHeight: image.height
                )
            }
        }
        throw Failure.couldNotEncode
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length > 0 else { return nil }
        return encoded as Data
    }
}
