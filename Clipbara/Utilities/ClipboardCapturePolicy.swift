import Foundation

/// Rules for what clipboard capture is allowed to persist.
///
/// Kept free of SwiftData and AppKit so the retention and identity decisions
/// can be tested without a store or a pasteboard.
enum ClipboardCapturePolicy {

    /// How duplicate detection identifies a clip.
    ///
    /// Sensitive clips are passwords and other secrets. An unsalted SHA-256 of
    /// that plaintext can be cracked offline from the database alone, so those
    /// clips use a keychain-keyed MAC instead.
    enum IdentityAlgorithm: Equatable {
        case sha256
        case keyedMac
    }

    static func identityAlgorithm(isSensitive: Bool) -> IdentityAlgorithm {
        isSensitive ? .keyedMac : .sha256
    }

    /// History limit eviction. Pinned clips are kept on purpose. Sensitive clips
    /// already expire on their own timer, so counting them would delete a durable
    /// clip to make room for something that is about to erase itself.
    static func isEvictable(isPinned: Bool, isSensitive: Bool) -> Bool {
        !isPinned && !isSensitive
    }
}
