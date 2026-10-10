import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ForeverLM

@Suite("Chat image preparation")
struct ChatImagePreparationTests {
    /// A solid-colour picture of the given size, encoded as `type`.
    private func encodedImage(width: Int, height: Int, alpha: Bool, type: UTType) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: info.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    @Test("A small PNG is kept byte for byte")
    func smallPNGIsKept() throws {
        let png = try encodedImage(width: 320, height: 200, alpha: false, type: .png)
        let prepared = try ChatImagePreparation.prepare(png)
        #expect(prepared.image.data == png)
        #expect(prepared.image.mediaType == "image/png")
        #expect(prepared.pixelWidth == 320)
        #expect(prepared.pixelHeight == 200)
    }

    @Test("An oversized photo is scaled to the long-edge limit and re-encoded as JPEG")
    func oversizedPhotoIsScaled() throws {
        let jpeg = try encodedImage(width: 4000, height: 1000, alpha: false, type: .jpeg)
        let prepared = try ChatImagePreparation.prepare(jpeg)
        #expect(prepared.image.mediaType == "image/jpeg")
        #expect(prepared.pixelWidth == ChatImagePreparation.maxPixelSize)
        #expect(prepared.pixelHeight == ChatImagePreparation.maxPixelSize / 4)
        #expect(pixelSize(of: prepared.image.data)! == (ChatImagePreparation.maxPixelSize, ChatImagePreparation.maxPixelSize / 4))
        #expect(prepared.image.data.count <= ChatImagePreparation.maxByteCount)
    }

    @Test("A type no vision route reads is converted, keeping transparency as PNG")
    func tiffIsConverted() throws {
        let tiff = try encodedImage(width: 300, height: 300, alpha: true, type: .tiff)
        let prepared = try ChatImagePreparation.prepare(tiff)
        #expect(prepared.image.mediaType == "image/png")
        #expect(prepared.pixelWidth == 300)
        #expect(pixelSize(of: prepared.image.data)! == (300, 300))

        let opaqueTIFF = try encodedImage(width: 300, height: 300, alpha: false, type: .tiff)
        #expect(try ChatImagePreparation.prepare(opaqueTIFF).image.mediaType == "image/jpeg")
    }

    @Test("Bytes that are not a picture are refused with a message the learner can read")
    func garbageIsRefused() {
        #expect(throws: ChatImagePreparation.Failure.notAnImage) {
            try ChatImagePreparation.prepare(Data("not a picture".utf8))
        }
        #expect(throws: ChatImagePreparation.Failure.notAnImage) {
            try ChatImagePreparation.prepare(Data())
        }
        #expect(ChatImagePreparation.Failure.notAnImage.errorDescription?.isEmpty == false)
    }
}
