import Foundation

/// Tracks which general-pasteboard generations this app wrote itself.
///
/// Clipboard monitoring polls `changeCount`. A "skip the next poll" flag treats
/// every change that arrives before that poll as our own write, so a copy the
/// user makes immediately after pasting is thrown away. Sampling the count
/// after our write closes only that generation; a later copy still has a
/// higher count and is recorded.
struct PasteboardChangeTracker: Equatable {
    private(set) var lastChangeCount: Int

    init(changeCount: Int) {
        self.lastChangeCount = changeCount
    }

    /// Call on the main thread immediately after this process finishes writing
    /// the general pasteboard, before returning to the run loop.
    mutating func noteOwnWrite(changeCount: Int) {
        lastChangeCount = changeCount
    }

    /// Returns whether `changeCount` is a new external change that should be stored.
    mutating func consume(_ changeCount: Int) -> Bool {
        guard changeCount != lastChangeCount else { return false }
        lastChangeCount = changeCount
        return true
    }
}
