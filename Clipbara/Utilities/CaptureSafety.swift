import Foundation

/// Decisions that keep clipboard capture from leaking secrets or dropping an
/// explicit screenshot. Kept free of AppKit so the rules can be tested directly.
enum CaptureSafety {
    /// Excluded apps are not recorded. An interactive screenshot is the
    /// exception: `screencapture` copies the image only after the user finishes,
    /// by which time the app they were capturing is frontmost again. Treating
    /// that image as an ordinary excluded copy deletes it.
    static func shouldRecordDespiteExclusion(expectingScreenshot: Bool, isImage: Bool) -> Bool {
        expectingScreenshot && isImage
    }

    /// Sensitive images are encrypted in the store and are not given a
    /// thumbnail, because a plaintext file would outlive the auto-erase TTL.
    /// Paste and drag must follow the same rule. Ordinary images still write a
    /// temp PNG so file-oriented apps (Ghostty) can paste them.
    static func shouldWritePlaintextImageFile(isSensitive: Bool) -> Bool {
        !isSensitive
    }
}
