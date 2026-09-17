import CryptoKit
import Foundation

/// SHA-256 in the one form every record and artifact name uses: lowercase hex.
public enum SHA256Digest {
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(_ text: String) -> String {
        hex(Data(text.utf8))
    }

    /// True when a string is a lowercase 64-character hex digest.
    public static func isValid(_ digest: String) -> Bool {
        guard digest.utf8.count == 64 else { return false }
        return digest.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }
}
