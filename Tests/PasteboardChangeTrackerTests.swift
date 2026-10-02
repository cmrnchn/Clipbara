import XCTest

final class PasteboardChangeTrackerTests: XCTestCase {
    func testOwnWriteIsNotRecorded() {
        var tracker = PasteboardChangeTracker(changeCount: 10)
        // clearContents + setString commonly advance the count by more than one.
        tracker.noteOwnWrite(changeCount: 12)
        XCTAssertFalse(tracker.consume(12))
    }

    func testCopyMadeAfterPasteIsRecorded() {
        var tracker = PasteboardChangeTracker(changeCount: 10)
        tracker.noteOwnWrite(changeCount: 12)
        XCTAssertTrue(tracker.consume(13))
        XCTAssertFalse(tracker.consume(13))
    }

    func testExternalCopyIsRecorded() {
        var tracker = PasteboardChangeTracker(changeCount: 4)
        XCTAssertFalse(tracker.consume(4))
        XCTAssertTrue(tracker.consume(5))
    }

    func testLaterCopyInTheSamePollWindowIsKept() {
        // Our write lands on 11, then the user copies before the next poll and
        // the count is 12. Only the user's copy is new relative to our write.
        var tracker = PasteboardChangeTracker(changeCount: 10)
        tracker.noteOwnWrite(changeCount: 11)
        XCTAssertTrue(tracker.consume(12))
        XCTAssertEqual(tracker.lastChangeCount, 12)
    }
}
