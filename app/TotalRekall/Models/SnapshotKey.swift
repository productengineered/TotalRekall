import CryptoKit
import Foundation

/// Builds the snapshots.json dictionary key from the set of connected panel serials.
enum SnapshotKey {
    /// SHA-256 hex of the sorted, serials joined with "|". Order-independent.
    /// Identical panels have distinct serials, so duplicates are preserved (sorted, not uniqued).
    static func make(panelSerials: [String]) -> String {
        let joined = panelSerials.sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
