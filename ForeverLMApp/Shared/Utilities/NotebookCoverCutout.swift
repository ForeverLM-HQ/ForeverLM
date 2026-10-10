import CoreGraphics
import Foundation

/// A notebook cover without its ground. The drawn pictures are opaque squares: a flat pale ground, and
/// most often a rounded "app icon" tile in the middle of it, so the subject itself fills about half of
/// the frame. Drawn at 14 to 44 points that reads as a small icon on a coloured square, and "just the
/// icon" is what the learner asked for (product owner, 2026-10-06). This takes the ground away and crops to
/// what is drawn, without changing the stored picture: the bytes stay the content-addressed JPEG every
/// device has, and each app cuts a picture once (`NotebookCoverImages` on the Mac,
/// `MobileNotebookCoverImages` on the iPhone; the web's twin is `bareNotebookCover`).
///
/// The ground is the colour of the picture's border, and only what touches the border in that colour
/// goes, so a white tile on a cream ground goes with it, while a coloured tile, or a pale patch inside
/// the subject, stays. A picture whose border is not one flat colour (a gradient, a photograph, a
/// checkerboard the model drew for "transparent"), one that is nearly all ground or none, and one whose
/// subject is nearly white (it would vanish on a light window) are left as drawn: `bare` returns nil.
enum NotebookCoverCutout {
    /// How far a pixel (its largest channel difference, 0…255) may be from the ground and still be it.
    static let groundTolerance = 22
    /// How far from the ground a pixel must be to be wholly the subject. Between the two it is an
    /// anti-aliased rim, drawn translucent with the ground taken out of its colour.
    static let solidDistance = 100
    /// A soft glow or shadow round the subject leaves the ground's colour slowly: a pixel up to this far
    /// from it is still ground when it differs by no more than `smoothStep` from the ground pixel it
    /// follows, so the fill rolls down a gradient and stops at the subject's edge.
    static let smoothDistance = 70
    static let smoothStep = 7
    /// The longest side the cut works at: a cover is stored at 512.
    static let workingSide = 512
    /// What the picture's border may vary by (mean absolute deviation, per channel) and still be one flat colour.
    static let flatGroundSpread = 10.0
    /// The share of the picture that must be ground, and may be.
    static let groundShare = 0.05...0.97
    /// The subject's average brightness (0…1) above which it is left on its ground.
    static let nearlyWhite = 0.92
    /// Space around the subject, as a share of its longest side.
    static let marginShare = 0.04

    static func bare(_ source: CGImage) -> CGImage? {
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, Double(workingSide) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        let count = width * height
        var pixels = [UInt8](repeating: 0, count: count * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // The ground: the median colour of the border, which must be flat.
        let ring = max(2, min(width, height) / 100)
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width where x < ring || x >= width - ring || y < ring || y >= height - ring {
                let i = (y * width + x) * 4
                reds.append(pixels[i]); greens.append(pixels[i + 1]); blues.append(pixels[i + 2])
            }
        }
        func median(_ values: [UInt8]) -> Int { Int(values.sorted()[values.count / 2]) }
        let ground = (red: median(reds), green: median(greens), blue: median(blues))
        var deviation = 0
        for k in 0..<reds.count {
            deviation += abs(Int(reds[k]) - ground.red) + abs(Int(greens[k]) - ground.green) + abs(Int(blues[k]) - ground.blue)
        }
        guard Double(deviation) / Double(reds.count * 3) <= flatGroundSpread else { return nil }

        func distance(_ pixel: Int) -> Int {
            let i = pixel * 4
            return max(abs(Int(pixels[i]) - ground.red), abs(Int(pixels[i + 1]) - ground.green), abs(Int(pixels[i + 2]) - ground.blue))
        }

        // The ground is what reaches the border in the ground's colour, or rolls down to it.
        var isGround = [Bool](repeating: false, count: count)
        var pending: [Int] = []
        func take(_ pixel: Int, after previous: Int?) {
            guard !isGround[pixel] else { return }
            let far = distance(pixel)
            var joins = far <= groundTolerance
            if !joins, far <= smoothDistance, let previous {
                let a = pixel * 4, b = previous * 4
                let step = max(abs(Int(pixels[a]) - Int(pixels[b])), abs(Int(pixels[a + 1]) - Int(pixels[b + 1])), abs(Int(pixels[a + 2]) - Int(pixels[b + 2])))
                joins = step <= smoothStep
            }
            guard joins else { return }
            isGround[pixel] = true
            pending.append(pixel)
        }
        for x in 0..<width { take(x, after: nil); take((height - 1) * width + x, after: nil) }
        for y in 0..<height { take(y * width, after: nil); take(y * width + width - 1, after: nil) }
        while let pixel = pending.popLast() {
            let x = pixel % width, y = pixel / width
            if x > 0 { take(pixel - 1, after: pixel) }
            if x < width - 1 { take(pixel + 1, after: pixel) }
            if y > 0 { take(pixel - width, after: pixel) }
            if y < height - 1 { take(pixel + width, after: pixel) }
        }
        let groundCount = isGround.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard groundShare.contains(Double(groundCount) / Double(count)) else { return nil }

        // The rim: two pixels of what is left, next to the ground, are translucent in proportion to how
        // far from the ground beside them they are, with that ground's share taken out of their colour.
        var steps = [UInt8](repeating: 0, count: count)
        var reference = [Int32](repeating: -1, count: count)
        for step in 1...2 {
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = y * width + x
                    guard !isGround[pixel], steps[pixel] == 0 else { continue }
                    var found: Int?
                    if x > 0, step == 1 ? isGround[pixel - 1] : steps[pixel - 1] == 1 { found = pixel - 1 }
                    else if x < width - 1, step == 1 ? isGround[pixel + 1] : steps[pixel + 1] == 1 { found = pixel + 1 }
                    else if y > 0, step == 1 ? isGround[pixel - width] : steps[pixel - width] == 1 { found = pixel - width }
                    else if y < height - 1, step == 1 ? isGround[pixel + width] : steps[pixel + width] == 1 { found = pixel + width }
                    if let found {
                        steps[pixel] = UInt8(step)
                        reference[pixel] = step == 1 ? Int32(found) : reference[found]
                    }
                }
            }
        }
        var cut = [UInt8](repeating: 0, count: count * 4)
        var minX = width, maxX = -1, minY = height, maxY = -1
        var subjectCount = 0
        var brightness = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                guard !isGround[pixel] else { continue }
                var base = [Double](repeating: 0, count: 3)
                var alpha = 1.0
                if steps[pixel] > 0, reference[pixel] >= 0 {
                    let near = Int(reference[pixel]) * 4
                    var far = 0
                    for k in 0..<3 {
                        base[k] = Double(pixels[near + k])
                        far = max(far, abs(Int(pixels[pixel * 4 + k]) - Int(pixels[near + k])))
                    }
                    alpha = min(1, max(0, Double(far - groundTolerance) / Double(solidDistance - groundTolerance)))
                    if alpha < 0.06 { continue }
                }
                var unmatted = [Double](repeating: 0, count: 3)
                for k in 0..<3 {
                    let value = Double(pixels[pixel * 4 + k])
                    unmatted[k] = alpha < 1 ? min(255, max(0, base[k] + (value - base[k]) / alpha)) : value
                    cut[pixel * 4 + k] = UInt8((unmatted[k] * alpha).rounded())
                }
                cut[pixel * 4 + 3] = UInt8((alpha * 255).rounded())
                if alpha >= 0.5 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    subjectCount += 1
                    brightness += (0.2126 * unmatted[0] + 0.7152 * unmatted[1] + 0.0722 * unmatted[2]) / 255
                }
            }
        }
        guard subjectCount * 200 >= count, maxX >= minX, brightness / Double(subjectCount) <= nearlyWhite else { return nil }

        // Cropped to the subject, centred in a square with a little room around it.
        let subjectWidth = maxX - minX + 1, subjectHeight = maxY - minY + 1
        let side = max(subjectWidth, subjectHeight)
        let margin = max(2, Int((Double(side) * marginShare).rounded()))
        let outSide = side + 2 * margin
        let originX = minX - (outSide - subjectWidth) / 2
        let originY = minY - (outSide - subjectHeight) / 2
        var square = [UInt8](repeating: 0, count: outSide * outSide * 4)
        for y in 0..<outSide {
            let sourceY = originY + y
            guard sourceY >= 0, sourceY < height else { continue }
            for x in 0..<outSide {
                let sourceX = originX + x
                guard sourceX >= 0, sourceX < width else { continue }
                let from = (sourceY * width + sourceX) * 4, to = (y * outSide + x) * 4
                for k in 0..<4 { square[to + k] = cut[from + k] }
            }
        }
        guard let provider = CGDataProvider(data: Data(square) as CFData) else { return nil }
        return CGImage(
            width: outSide, height: outSide, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outSide * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
