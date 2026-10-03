import XCTest

final class BackupMergePolicyTests: XCTestCase {
    func testSensitiveRowsAreNotReuseTargets() {
        XCTAssertFalse(BackupMergePolicy.canReuseExistingItem(isSensitive: true))
        XCTAssertTrue(BackupMergePolicy.canReuseExistingItem(isSensitive: false))
    }

    func testBoardMembershipPinsTheMergedClip() {
        XCTAssertTrue(BackupMergePolicy.shouldPin(wasPinned: false, backupSaysPinned: false, placedOnBoard: true))
        XCTAssertTrue(BackupMergePolicy.shouldPin(wasPinned: false, backupSaysPinned: true, placedOnBoard: false))
        XCTAssertTrue(BackupMergePolicy.shouldPin(wasPinned: true, backupSaysPinned: false, placedOnBoard: false))
        XCTAssertFalse(BackupMergePolicy.shouldPin(wasPinned: false, backupSaysPinned: false, placedOnBoard: false))
    }
}
