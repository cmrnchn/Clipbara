import XCTest

final class ClipboardCapturePolicyTests: XCTestCase {
    func testSensitiveClipsDoNotStoreAnUnsaltedPlaintextHash() {
        XCTAssertEqual(ClipboardCapturePolicy.identityAlgorithm(isSensitive: true), .keyedMac)
        XCTAssertEqual(ClipboardCapturePolicy.identityAlgorithm(isSensitive: false), .sha256)
    }

    func testSensitiveClipsDoNotConsumeDurableHistorySlots() {
        XCTAssertFalse(ClipboardCapturePolicy.isEvictable(isPinned: false, isSensitive: true))
        XCTAssertFalse(ClipboardCapturePolicy.isEvictable(isPinned: true, isSensitive: true))
        XCTAssertFalse(ClipboardCapturePolicy.isEvictable(isPinned: true, isSensitive: false))
        XCTAssertTrue(ClipboardCapturePolicy.isEvictable(isPinned: false, isSensitive: false))
    }
}
