import CryptoKit
import Foundation

extension Sequence where Element == UInt8 {
    /// Lowercase hexadecimal, two digits a byte: the form every stored digest,
    /// cache key and content hash in the app uses.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    /// The SHA-256 of these bytes, as lowercase hexadecimal.
    var sha256Hex: String {
        SHA256.hash(data: self).hexString
    }
}

extension String {
    /// The SHA-256 of this text's UTF-8 bytes, as lowercase hexadecimal.
    var sha256Hex: String {
        Data(utf8).sha256Hex
    }
}
