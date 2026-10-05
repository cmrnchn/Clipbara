import XCTest

final class StoreRecoveryTests: XCTestCase {
    private let fm = FileManager.default
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories {
            try? fm.removeItem(at: directory)
        }
        directories = []
        super.tearDown()
    }

    func testSnapshotLeavesTheCommittedBackupUntouched() throws {
        let store = try makeStore()
        try commit(Data("good".utf8), to: store)

        try Data("corrupt".utf8).write(to: store)
        let snapshot = StoreManager.captureSnapshot(at: store)
        guard case .captured(let staging) = snapshot else {
            return XCTFail("expected a snapshot of the closed store")
        }

        XCTAssertEqual(try Data(contentsOf: backupURL(for: store)), Data("good".utf8))
        StoreManager.discardSnapshot(staging)
        XCTAssertEqual(try Data(contentsOf: backupURL(for: store)), Data("good".utf8))
        XCTAssertEqual(try Data(contentsOf: store), Data("corrupt".utf8))
    }

    func testDiscardedSnapshotStillRestoresTheLastOpenedBackup() throws {
        let store = try makeStore()
        try commit(Data("good".utf8), to: store)
        try Data("corrupt".utf8).write(to: store)

        let snapshot = StoreManager.captureSnapshot(at: store)
        guard case .captured(let staging) = snapshot else {
            return XCTFail("expected a snapshot")
        }
        StoreManager.discardSnapshot(staging)

        XCTAssertTrue(StoreManager.restoreBackup(at: store))
        XCTAssertEqual(try Data(contentsOf: store), Data("good".utf8))
        XCTAssertEqual(try Data(contentsOf: backupURL(for: store)), Data("good".utf8))
        XCTAssertEqual(try Data(contentsOf: try quarantinedCopy(of: "PasteClip.store", near: store)), Data("corrupt".utf8))
    }

    func testCommitSnapshotReplacesTheBackup() throws {
        let store = try makeStore()
        try commit(Data("v1".utf8), to: store)
        try commit(Data("v2".utf8), to: store)

        XCTAssertTrue(StoreManager.restoreBackup(at: store))
        XCTAssertEqual(try Data(contentsOf: store), Data("v2".utf8))
    }

    func testPreOpenSnapshotIsRestoredBeforeTheOlderBackup() throws {
        let store = try makeStore()
        try commit(Data("old".utf8), to: store)
        try Data("latest".utf8).write(to: store)

        let snapshot = StoreManager.captureSnapshot(at: store)
        guard case .captured(let staging) = snapshot else {
            return XCTFail("expected a snapshot")
        }
        try Data("damaged".utf8).write(to: store)

        XCTAssertTrue(StoreManager.restoreSnapshot(staging, over: store))
        XCTAssertEqual(try Data(contentsOf: store), Data("latest".utf8))
        XCTAssertEqual(try Data(contentsOf: backupURL(for: store)), Data("old".utf8))
        XCTAssertTrue(StoreManager.commitSnapshot(staging, for: store))
        XCTAssertEqual(try Data(contentsOf: backupURL(for: store)), Data("latest".utf8))
    }

    func testRestoreWithoutABackupLeavesTheLiveStoreAlone() throws {
        let store = try makeStore()
        try Data("only-copy".utf8).write(to: store)

        XCTAssertFalse(StoreManager.restoreBackup(at: store))
        XCTAssertEqual(try Data(contentsOf: store), Data("only-copy".utf8))
    }

    func testACheckpointedSnapshotDropsThePreviousWAL() throws {
        let store = try makeStore()
        let directory = store.deletingLastPathComponent()
        try Data("db-v1".utf8).write(to: store)
        try Data("wal-v1".utf8).write(to: directory.appendingPathComponent("PasteClip.store-wal"))
        let first = StoreManager.captureSnapshot(at: store)
        guard case .captured(let firstStaging) = first else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertTrue(StoreManager.commitSnapshot(firstStaging, for: store))

        try fm.removeItem(at: directory.appendingPathComponent("PasteClip.store-wal"))
        try Data("db-v2".utf8).write(to: store)
        let second = StoreManager.captureSnapshot(at: store)
        guard case .captured(let secondStaging) = second else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertTrue(StoreManager.commitSnapshot(secondStaging, for: store))

        XCTAssertEqual(try Data(contentsOf: backupURL(for: store)), Data("db-v2".utf8))
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("PasteClip.store.backup-wal").path))
    }

    func testExternalStorageRoundTripsThroughTheBackup() throws {
        let store = try makeStore()
        let directory = store.deletingLastPathComponent()
        try Data("db".utf8).write(to: store)
        let support = directory.appendingPathComponent(".PasteClip_SUPPORT")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: support.appendingPathComponent("blob"))

        let snapshot = StoreManager.captureSnapshot(at: store)
        guard case .captured(let staging) = snapshot else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertTrue(StoreManager.commitSnapshot(staging, for: store))

        try Data("newer".utf8).write(to: support.appendingPathComponent("blob"))
        XCTAssertTrue(StoreManager.restoreBackup(at: store))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(".PasteClip_SUPPORT/blob")),
            Data("image".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(".PasteClip_SUPPORT.backup/blob")),
            Data("image".utf8)
        )
    }

    func testArchivingMovesTheBackupOutOfTheSlotALaterCommitReplaces() throws {
        let store = try makeStore()
        try commit(Data("good".utf8), to: store)
        let preserved = try Data(contentsOf: backupURL(for: store))

        let folder = try XCTUnwrap(StoreManager.archiveUnopenedFiles(at: store))
        XCTAssertFalse(fm.fileExists(atPath: store.path))
        XCTAssertFalse(fm.fileExists(atPath: backupURL(for: store).path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("PasteClip.store.backup")), preserved)

        try commit(Data("fresh".utf8), to: store)
        XCTAssertEqual(try Data(contentsOf: backupURL(for: store)), Data("fresh".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("PasteClip.store.backup")), preserved)
    }

    func testMissingStoreDoesNotInventABackup() throws {
        let directory = try makeTempDirectory()
        let store = directory.appendingPathComponent("PasteClip.store")
        guard case .noStore = StoreManager.captureSnapshot(at: store) else {
            return XCTFail("expected noStore")
        }
        XCTAssertFalse(fm.fileExists(atPath: backupURL(for: store).path))
    }

    private func makeStore() throws -> URL {
        let directory = try makeTempDirectory()
        return directory.appendingPathComponent("PasteClip.store")
    }

    private func makeTempDirectory() throws -> URL {
        let directory = fm.temporaryDirectory
            .appendingPathComponent("clipbara-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func commit(_ data: Data, to store: URL) throws {
        try data.write(to: store)
        let snapshot = StoreManager.captureSnapshot(at: store)
        guard case .captured(let staging) = snapshot else {
            XCTFail("expected a snapshot")
            return
        }
        XCTAssertTrue(StoreManager.commitSnapshot(staging, for: store))
    }

    private func backupURL(for store: URL) -> URL {
        store.deletingLastPathComponent().appendingPathComponent("PasteClip.store.backup")
    }

    private func quarantinedCopy(of name: String, near store: URL) throws -> URL {
        let matches = try fm.contentsOfDirectory(
            at: store.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Quarantine-") }
        let folder = try XCTUnwrap(matches.first)
        return folder.appendingPathComponent(name)
    }
}
