import Foundation

extension String {
    /// Repairs text whose UTF-8 bytes were accidentally interpreted as
    /// Windows-1252 one or more times (for example, `itâ€™s` instead of `it’s`).
    ///
    /// The repair is deliberately byte-structural: it only replaces a sequence
    /// when its Windows-1252 byte values form one complete, valid non-ASCII UTF-8
    /// scalar. Ordinary accented text is therefore left alone, while the common
    /// two-, three-, and four-byte mojibake forms are restored. A few bounded
    /// passes also recover content that an upstream publisher encoded twice.
    func repairingUTF8Mojibake() -> String {
        var repaired = self
        for _ in 0..<3 {
            let pass = repaired.repairingOneUTF8MojibakePass()
            guard pass != repaired else { break }
            repaired = pass
        }
        return repaired
    }

    private func repairingOneUTF8MojibakePass() -> String {
        let scalars = Array(unicodeScalars)
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)
        var index = 0

        while index < scalars.count {
            guard let lead = Self.windows1252Byte(for: scalars[index]) else {
                result.append(scalars[index])
                index += 1
                continue
            }
            let length: Int
            switch lead {
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default:
                result.append(scalars[index])
                index += 1
                continue
            }
            guard index + length <= scalars.count else {
                result.append(scalars[index])
                index += 1
                continue
            }

            let bytes = scalars[index..<(index + length)].compactMap(Self.windows1252Byte(for:))
            guard bytes.count == length,
                  bytes.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }),
                  let decoded = String(data: Data(bytes), encoding: .utf8) else {
                result.append(scalars[index])
                index += 1
                continue
            }
            result.append(contentsOf: decoded.unicodeScalars)
            index += length
        }
        return String(result)
    }

    /// The Unicode scalar-to-byte half of Windows-1252. C1 controls are also
    /// accepted because some publishers used ISO-8859-1 for the mistaken decode.
    private static func windows1252Byte(for scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        if value <= 0xFF { return UInt8(value) }
        switch value {
        case 0x20AC: return 0x80 // €
        case 0x201A: return 0x82 // ‚
        case 0x0192: return 0x83 // ƒ
        case 0x201E: return 0x84 // „
        case 0x2026: return 0x85 // …
        case 0x2020: return 0x86 // †
        case 0x2021: return 0x87 // ‡
        case 0x02C6: return 0x88 // ˆ
        case 0x2030: return 0x89 // ‰
        case 0x0160: return 0x8A // Š
        case 0x2039: return 0x8B // ‹
        case 0x0152: return 0x8C // Œ
        case 0x017D: return 0x8E // Ž
        case 0x2018: return 0x91 // ‘
        case 0x2019: return 0x92 // ’
        case 0x201C: return 0x93 // “
        case 0x201D: return 0x94 // ”
        case 0x2022: return 0x95 // •
        case 0x2013: return 0x96 // –
        case 0x2014: return 0x97 // —
        case 0x02DC: return 0x98 // ˜
        case 0x2122: return 0x99 // ™
        case 0x0161: return 0x9A // š
        case 0x203A: return 0x9B // ›
        case 0x0153: return 0x9C // œ
        case 0x017E: return 0x9E // ž
        case 0x0178: return 0x9F // Ÿ
        default: return nil
        }
    }
}
