import Foundation

/// Rules for merging a JSON backup into an existing library.
///
/// History eviction deletes every clip with `isPinned == false`, and it deletes
/// that clip's pinboard entries too. Sensitive clips are erased on a timer the
/// same way, pin or not. A backup clip is durable, so the merge has to land it
/// on a row that will still be there after the next capture.
enum BackupMergePolicy {

    /// A sensitive row auto-erases and takes any pinboard entry with it.
    /// Reusing it because the plaintext hash matches drops the backup clip.
    static func canReuseExistingItem(isSensitive: Bool) -> Bool {
        !isSensitive
    }

    /// Pinboard membership only survives eviction when the clip is pinned.
    /// The backup's pin flag and a newly attached board entry both count.
    static func shouldPin(wasPinned: Bool, backupSaysPinned: Bool, placedOnBoard: Bool) -> Bool {
        wasPinned || backupSaysPinned || placedOnBoard
    }
}
