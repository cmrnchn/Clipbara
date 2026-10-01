import XCTest

final class CaptureSafetyTests: XCTestCase {
    func testExplicitScreenshotIsKeptWhenFrontAppIsExcluded() {
        XCTAssertTrue(CaptureSafety.shouldRecordDespiteExclusion(expectingScreenshot: true, isImage: true))
    }

    func testExcludedAppStillDropsOrdinaryCaptures() {
        XCTAssertFalse(CaptureSafety.shouldRecordDespiteExclusion(expectingScreenshot: false, isImage: true))
        XCTAssertFalse(CaptureSafety.shouldRecordDespiteExclusion(expectingScreenshot: true, isImage: false))
        XCTAssertFalse(CaptureSafety.shouldRecordDespiteExclusion(expectingScreenshot: false, isImage: false))
    }

    func testSensitiveImagesAreNotWrittenAsPlaintextFiles() {
        XCTAssertFalse(CaptureSafety.shouldWritePlaintextImageFile(isSensitive: true))
        XCTAssertTrue(CaptureSafety.shouldWritePlaintextImageFile(isSensitive: false))
    }
}
