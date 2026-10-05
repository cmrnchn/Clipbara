import Foundation
import os.log

enum StoreManager {

    static let logger = Logger(
        subsystem: "com.minsang.PasteClip",
        category: "StoreManager"
    )

    private static let storeDirectoryName = "com.minsang.PasteClip"
    private static let storeFileName = "PasteClip.store"
    private static let legacyStoreFileName = "default.store"
    // SwiftData external storage: .{storeName_without_ext}_SUPPORT/_EXTERNAL_DATA/
    private static let legacySupportDirName = ".default_SUPPORT"
    private static let newSupportDirName = ".PasteClip_SUPPORT"

    /// 정식 store URL을 반환. 기존 default.store가 있으면 자동 마이그레이션.
    static func resolveStoreURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent(storeDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)

        let newStoreURL = appDir.appendingPathComponent(storeFileName)

        if fm.fileExists(atPath: newStoreURL.path) {
            logger.info("Using existing store at \(newStoreURL.path)")
            return newStoreURL
        }

        // 기존 default.store에서 마이그레이션
        let legacyURL = appSupport.appendingPathComponent(legacyStoreFileName)
        if fm.fileExists(atPath: legacyURL.path) {
            logger.info("Found legacy store, migrating...")
            migrateStore(from: legacyURL, to: newStoreURL, fm: fm)
        } else {
            logger.info("No existing store found, creating fresh")
        }

        return newStoreURL
    }

    /// Result of copying a closed store aside without touching the committed backup.
    enum Snapshot {
        /// No database file yet (first launch).
        case noStore
        /// Closed store copied aside. The committed backup was not modified.
        case captured(URL)
        /// The store exists, but the copy failed. The committed backup was not modified.
        case captureFailed
    }

    /// Copies the closed store to a staging directory.
    ///
    /// The committed backup is left alone. Call `commitSnapshot` only after the
    /// staged bytes have actually opened, and `discardSnapshot` if they have not.
    /// Replacing the backup before a successful open is what used to destroy the
    /// last good copy and then delete the unopenable store.
    static func captureSnapshot(at storeURL: URL) -> Snapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return .noStore }

        removeStaleSnapshots(near: storeURL)
        let staging = storeURL.deletingLastPathComponent()
            .appendingPathComponent(".store-snapshot-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try copyExistingSidecars(of: storeURL, into: staging)
            return .captured(staging)
        } catch {
            try? fm.removeItem(at: staging)
            logger.error("Failed to snapshot store: \(error.localizedDescription)")
            return .captureFailed
        }
    }

    /// Replaces the committed backup with a snapshot of a store that opened.
    static func commitSnapshot(_ staging: URL, for storeURL: URL) -> Bool {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }

        let stagedMain = staging.appendingPathComponent(storeURL.lastPathComponent)
        guard fm.fileExists(atPath: stagedMain.path) else { return false }

        do {
            try installBackup(from: staging, for: storeURL)
            logger.info("Backup updated")
            return true
        } catch {
            logger.error("Failed to commit store backup: \(error.localizedDescription)")
            return false
        }
    }

    static func discardSnapshot(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    /// Puts a pre-open snapshot back over the live store without deleting the snapshot.
    ///
    /// Used when opening the live file fails. The snapshot is the closed copy taken
    /// before that attempt, so it is preferred over the older committed backup.
    static func restoreSnapshot(_ staging: URL, over storeURL: URL) -> Bool {
        let fm = FileManager.default
        let stagedMain = staging.appendingPathComponent(storeURL.lastPathComponent)
        guard fm.fileExists(atPath: stagedMain.path) else { return false }

        // Swap each sidecar only after its replacement has been copied, so a
        // failed restore leaves the snapshot directory intact for a later attempt.
        do {
            try copySidecars(from: staging, onto: storeURL)
            return true
        } catch {
            logger.error("Failed to restore store snapshot: \(error.localizedDescription)")
            return false
        }
    }

    /// Moves the live store aside and copies the committed backup into its place.
    /// The backup itself is not removed.
    static func restoreBackup(at storeURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL(for: storeURL, suffix: "").path) else { return false }

        let live = existingLiveSidecars(of: storeURL)
        if !live.isEmpty {
            guard quarantine(live, near: storeURL) != nil else { return false }
        }

        do {
            try copyBackupOntoLive(storeURL)
            logger.info("Restored store from backup")
            return true
        } catch {
            logger.error("Failed to copy backup into place: \(error.localizedDescription)")
            return false
        }
    }

    /// Moves the live store and the committed backup out of the way so a new
    /// empty store can be created without overwriting the only remaining copy.
    @discardableResult
    static func archiveUnopenedFiles(at storeURL: URL) -> URL? {
        let sources = existingLiveSidecars(of: storeURL) + existingBackupSidecars(of: storeURL)
        guard !sources.isEmpty else { return nil }
        let folder = quarantine(sources, near: storeURL)
        if let folder {
            logger.error("Archived unopenable clipboard database at \(folder.path)")
        }
        return folder
    }

    // MARK: - Private

    private static let liveSuffixes = ["", "-wal", "-shm"]

    private static func removeStaleSnapshots(near storeURL: URL) {
        let fm = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".store-snapshot-") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func backupURL(for storeURL: URL, suffix: String) -> URL {
        let directory = storeURL.deletingLastPathComponent()
        return directory.appendingPathComponent(storeURL.lastPathComponent + ".backup" + suffix)
    }

    private static func supportURL(in directory: URL, marker: String) -> URL {
        directory.appendingPathComponent(newSupportDirName + marker)
    }

    private static func copyExistingSidecars(of storeURL: URL, into staging: URL) throws {
        let fm = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        for suffix in liveSuffixes {
            let source = directory.appendingPathComponent(name + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: staging.appendingPathComponent(name + suffix))
        }

        let support = supportURL(in: directory, marker: "")
        if fm.fileExists(atPath: support.path) {
            try fm.copyItem(at: support, to: staging.appendingPathComponent(newSupportDirName))
        }
    }

    /// Writes every staged sidecar into the backup slot, then drops backup
    /// sidecars the snapshot does not have so an old WAL cannot replay onto
    /// the new database.
    private static func installBackup(from staging: URL, for storeURL: URL) throws {
        let name = storeURL.lastPathComponent
        let stagedMain = staging.appendingPathComponent(name)
        try replaceItem(
            at: backupURL(for: storeURL, suffix: ""),
            with: stagedMain,
            consumeSource: true
        )

        for suffix in ["-wal", "-shm"] {
            try installOrRemove(
                staged: staging.appendingPathComponent(name + suffix),
                destination: backupURL(for: storeURL, suffix: suffix),
                consumeSource: true
            )
        }
        try installOrRemove(
            staged: staging.appendingPathComponent(newSupportDirName),
            destination: supportURL(in: storeURL.deletingLastPathComponent(), marker: ".backup"),
            consumeSource: true
        )
    }

    private static func installOrRemove(staged: URL, destination: URL, consumeSource: Bool = false) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: staged.path) {
            try replaceItem(at: destination, with: staged, consumeSource: consumeSource)
        } else if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
    }

    /// Swaps `source` into `destination` only after the replacement bytes exist.
    /// A failed copy leaves the previous file in place. `consumeSource` moves
    /// the staged file instead of copying it a second time.
    private static func replaceItem(at destination: URL, with source: URL, consumeSource: Bool = false) throws {
        let fm = FileManager.default
        if consumeSource {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
            return
        }

        let temporary = destination.appendingPathExtension("tmp")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }

    private static func existingLiveSidecars(of storeURL: URL) -> [URL] {
        let fm = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        var urls = liveSuffixes.compactMap { suffix -> URL? in
            let url = directory.appendingPathComponent(name + suffix)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let support = supportURL(in: directory, marker: "")
        if fm.fileExists(atPath: support.path) {
            urls.append(support)
        }
        return urls
    }

    private static func existingBackupSidecars(of storeURL: URL) -> [URL] {
        let fm = FileManager.default
        var urls = liveSuffixes.compactMap { suffix -> URL? in
            let url = backupURL(for: storeURL, suffix: suffix)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let support = supportURL(in: storeURL.deletingLastPathComponent(), marker: ".backup")
        if fm.fileExists(atPath: support.path) {
            urls.append(support)
        }
        return urls
    }

    private static func copySidecars(from staging: URL, onto storeURL: URL) throws {
        let fm = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        for suffix in liveSuffixes {
            try installOrRemove(
                staged: staging.appendingPathComponent(name + suffix),
                destination: directory.appendingPathComponent(name + suffix)
            )
        }
        try installOrRemove(
            staged: staging.appendingPathComponent(newSupportDirName),
            destination: supportURL(in: directory, marker: "")
        )
    }

    private static func copyBackupOntoLive(_ storeURL: URL) throws {
        let fm = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        for suffix in liveSuffixes {
            let source = backupURL(for: storeURL, suffix: suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = directory.appendingPathComponent(name + suffix)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
        }

        let sourceSupport = supportURL(in: directory, marker: ".backup")
        guard fm.fileExists(atPath: sourceSupport.path) else { return }
        let destinationSupport = supportURL(in: directory, marker: "")
        if fm.fileExists(atPath: destinationSupport.path) {
            try fm.removeItem(at: destinationSupport)
        }
        try fm.copyItem(at: sourceSupport, to: destinationSupport)
    }

    @discardableResult
    private static func quarantine(_ sources: [URL], near storeURL: URL) -> URL? {
        let fm = FileManager.default
        guard !sources.isEmpty else { return nil }
        let folder = storeURL.deletingLastPathComponent()
            .appendingPathComponent(
                "Quarantine-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for source in sources {
                try fm.moveItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
            }
            return folder
        } catch {
            logger.error("Failed to quarantine store files: \(error.localizedDescription)")
            return nil
        }
    }

    private static func migrateStore(from source: URL, to destination: URL, fm: FileManager) {
        let sourceDir = source.deletingLastPathComponent()
        let destDir = destination.deletingLastPathComponent()
        let sourceName = source.lastPathComponent
        let destName = destination.lastPathComponent

        // .store, -wal, -shm 이동
        for suffix in ["", "-wal", "-shm"] {
            let src = sourceDir.appendingPathComponent(sourceName + suffix)
            let dst = destDir.appendingPathComponent(destName + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.moveItem(at: src, to: dst)
                logger.info("Moved \(src.lastPathComponent)")
            } catch {
                logger.error("Failed to move \(src.lastPathComponent): \(error.localizedDescription)")
                if suffix.isEmpty { return } // 메인 store 실패 시 중단
            }
        }

        // External storage 디렉토리 이동
        let srcSupport = sourceDir.appendingPathComponent(legacySupportDirName)
        let dstSupport = destDir.appendingPathComponent(newSupportDirName)
        if fm.fileExists(atPath: srcSupport.path) {
            do {
                try fm.moveItem(at: srcSupport, to: dstSupport)
                logger.info("Moved external storage directory")
            } catch {
                logger.error("Failed to move external storage: \(error.localizedDescription)")
            }
        }

        // 레거시 백업 정리
        for suffix in [".backup", ".backup-wal", ".backup-shm"] {
            try? fm.removeItem(at: sourceDir.appendingPathComponent(sourceName + suffix))
        }

        logger.info("Migration complete")
    }
}
