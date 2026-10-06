import Foundation
import SwiftData

/// JSON backup document for migrating history between installs
/// (e.g. from the Developer ID build to the sandboxed Mac App Store build).
struct TransferDocument: Codable {
    struct Item: Codable {
        var id: UUID
        var contentType: String
        var rawData: Data
        var textContent: String?
        var thumbnailData: Data?
        var sourceAppName: String?
        var sourceAppBundleId: String?
        var contentHash: String
        var copiedAt: Date
        var userTitle: String?
        var isPinned: Bool
    }

    struct Board: Codable {
        var id: UUID
        var name: String
        var displayOrder: Int
        var createdAt: Date
    }

    struct Entry: Codable {
        var pinboardID: UUID
        var itemID: UUID
        var displayOrder: Int
        var addedAt: Date
    }

    struct Exclusion: Codable {
        var bundleId: String
        var appName: String
    }

    var version: Int
    var exportedAt: Date
    var items: [Item]
    var pinboards: [Board]
    var entries: [Entry]
    var exclusions: [Exclusion]
    /// Absent on backups written before sensitive rules were included.
    var sensitiveRules: [SensitiveRuleBackup]?
}

@MainActor
enum TransferService {

    struct ImportSummary {
        var importedItems = 0
        var skippedItems = 0
        var importedBoards = 0
        var importedEntries = 0
        var importedExclusions = 0
        var importedSensitiveRules = 0
    }

    // MARK: - Export

    static func exportDocument(context: ModelContext) throws -> Data {
        // Sensitive items are encrypted with a key tied to this device's Keychain and
        // meant to auto-erase — they never leave the device in a backup.
        let items = try context.fetch(FetchDescriptor<ClipboardItem>()).filter { !$0.isSensitive }
        let boards = try context.fetch(FetchDescriptor<Pinboard>())
        let exclusions = try context.fetch(FetchDescriptor<ExcludedApp>())
        let sensitiveRules = try context.fetch(FetchDescriptor<SensitiveRule>())

        var entryRecords: [TransferDocument.Entry] = []
        for board in boards {
            for entry in board.entries {
                guard let item = entry.clipboardItem else { continue }
                entryRecords.append(TransferDocument.Entry(
                    pinboardID: board.id,
                    itemID: item.id,
                    displayOrder: entry.displayOrder,
                    addedAt: entry.addedAt
                ))
            }
        }

        let doc = TransferDocument(
            version: 1,
            exportedAt: Date(),
            items: items.map { item in
                TransferDocument.Item(
                    id: item.id,
                    contentType: item.contentTypeRaw,
                    rawData: item.rawData,
                    textContent: item.textContent,
                    thumbnailData: item.thumbnailData,
                    sourceAppName: item.sourceAppName,
                    sourceAppBundleId: item.sourceAppBundleId,
                    contentHash: item.contentHash,
                    copiedAt: item.copiedAt,
                    userTitle: item.userTitle,
                    isPinned: item.isPinned
                )
            },
            pinboards: boards.map { board in
                TransferDocument.Board(
                    id: board.id,
                    name: board.name,
                    displayOrder: board.displayOrder,
                    createdAt: board.createdAt
                )
            },
            entries: entryRecords,
            exclusions: exclusions.map { exclusion in
                TransferDocument.Exclusion(bundleId: exclusion.bundleId, appName: exclusion.appName)
            },
            sensitiveRules: sensitiveRules.map { rule in
                SensitiveRuleBackup(kind: rule.kindRaw, pattern: rule.pattern, displayName: rule.displayName)
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    // MARK: - Import

    /// Merges a backup into the current store. Items are deduplicated by
    /// content hash, pinboards by name, exclusions by bundle identifier,
    /// and sensitive rules by kind and pattern.
    static func importDocument(_ data: Data, context: ModelContext) throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(TransferDocument.self, from: data)

        var summary = ImportSummary()

        // Items (dedupe by contentHash)
        let existingItems = try context.fetch(FetchDescriptor<ClipboardItem>())
        var itemsByHash: [String: ClipboardItem] = [:]
        for item in existingItems { itemsByHash[item.contentHash] = item }

        var itemByExportID: [UUID: ClipboardItem] = [:]
        for record in doc.items {
            if let existing = itemsByHash[record.contentHash] {
                itemByExportID[record.id] = existing
                summary.skippedItems += 1
                continue
            }
            let item = ClipboardItem(
                contentType: ContentType(rawValue: record.contentType) ?? .unknown,
                rawData: record.rawData,
                textContent: record.textContent,
                thumbnailData: record.thumbnailData,
                sourceAppName: record.sourceAppName,
                sourceAppBundleId: record.sourceAppBundleId,
                contentHash: record.contentHash
            )
            item.copiedAt = record.copiedAt
            item.userTitle = record.userTitle
            item.isPinned = record.isPinned
            context.insert(item)
            itemsByHash[record.contentHash] = item
            itemByExportID[record.id] = item
            summary.importedItems += 1
        }

        // Pinboards (dedupe by name)
        let existingBoards = try context.fetch(FetchDescriptor<Pinboard>())
        var boardByName: [String: Pinboard] = [:]
        for board in existingBoards { boardByName[board.name] = board }

        var boardByExportID: [UUID: Pinboard] = [:]
        for record in doc.pinboards {
            if let existing = boardByName[record.name] {
                boardByExportID[record.id] = existing
                continue
            }
            let board = Pinboard(name: record.name, displayOrder: record.displayOrder)
            board.createdAt = record.createdAt
            context.insert(board)
            boardByName[record.name] = board
            boardByExportID[record.id] = board
            summary.importedBoards += 1
        }

        // Pinboard entries (skip if the board already contains the item)
        for record in doc.entries {
            guard let board = boardByExportID[record.pinboardID],
                  let item = itemByExportID[record.itemID] else { continue }
            let alreadyLinked = board.entries.contains { $0.clipboardItem?.contentHash == item.contentHash }
            if alreadyLinked { continue }
            let entry = PinboardEntry(clipboardItem: item, pinboard: board, displayOrder: record.displayOrder)
            entry.addedAt = record.addedAt
            context.insert(entry)
            summary.importedEntries += 1
        }

        // App exclusions (dedupe by bundle id)
        let existingExclusions = try context.fetch(FetchDescriptor<ExcludedApp>())
        var excludedIDs = Set(existingExclusions.map { $0.bundleId })
        for record in doc.exclusions {
            guard !excludedIDs.contains(record.bundleId) else { continue }
            context.insert(ExcludedApp(bundleId: record.bundleId, appName: record.appName))
            excludedIDs.insert(record.bundleId)
            summary.importedExclusions += 1
        }

        // Match patterns only. Sensitive clip payloads stay out of the backup.
        let existingRules = try context.fetch(FetchDescriptor<SensitiveRule>())
        let rulesToImport = SensitiveRuleBackupMerge.rulesToImport(
            existing: existingRules.map { rule in
                SensitiveRuleBackup(kind: rule.kindRaw, pattern: rule.pattern, displayName: rule.displayName)
            },
            incoming: doc.sensitiveRules ?? []
        )
        for record in rulesToImport {
            guard let kind = SensitiveRuleKind(rawValue: record.kind) else { continue }
            context.insert(SensitiveRule(kind: kind, pattern: record.pattern, displayName: record.displayName))
            summary.importedSensitiveRules += 1
        }

        try context.save()
        return summary
    }
}
