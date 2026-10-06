import XCTest

final class SensitiveRuleBackupTests: XCTestCase {
    func testImportsRulesThatAreNotAlreadyPresent() {
        let existing = [
            SensitiveRuleBackup(kind: "app", pattern: "com.1password.1password", displayName: "1Password")
        ]
        let incoming = [
            existing[0],
            SensitiveRuleBackup(kind: "domain", pattern: "MyBank.com", displayName: "MyBank.com"),
            SensitiveRuleBackup(kind: "process", pattern: "Terminal", displayName: "Terminal"),
        ]

        let imported = SensitiveRuleBackupMerge.rulesToImport(existing: existing, incoming: incoming)

        XCTAssertEqual(imported, [
            SensitiveRuleBackup(kind: "domain", pattern: "mybank.com", displayName: "MyBank.com"),
            SensitiveRuleBackup(kind: "process", pattern: "Terminal", displayName: "Terminal"),
        ])
    }

    func testProcessAndDomainDuplicatesAreCaseInsensitive() {
        let existing = [
            SensitiveRuleBackup(kind: "process", pattern: "Terminal", displayName: "Terminal"),
            SensitiveRuleBackup(kind: "domain", pattern: "mybank.com", displayName: "mybank.com"),
        ]
        let incoming = [
            SensitiveRuleBackup(kind: "process", pattern: "terminal", displayName: "terminal"),
            SensitiveRuleBackup(kind: "domain", pattern: "MyBank.com", displayName: "MyBank.com"),
        ]

        XCTAssertTrue(SensitiveRuleBackupMerge.rulesToImport(existing: existing, incoming: incoming).isEmpty)
    }

    func testDropsUnknownKindsAndBlankPatterns() {
        let incoming = [
            SensitiveRuleBackup(kind: "website", pattern: "mybank.com", displayName: "Bank"),
            SensitiveRuleBackup(kind: "app", pattern: "   ", displayName: "Blank"),
            SensitiveRuleBackup(kind: "app", pattern: "com.apple.Safari", displayName: ""),
        ]

        XCTAssertEqual(
            SensitiveRuleBackupMerge.rulesToImport(existing: [], incoming: incoming),
            [SensitiveRuleBackup(kind: "app", pattern: "com.apple.Safari", displayName: "com.apple.Safari")]
        )
    }

    func testOlderBackupWithoutRulesDecodesAsAbsent() throws {
        let json = Data(#"{"version":1,"exportedAt":"2026-09-17T12:00:00Z"}"#.utf8)
        let document = try JSONDecoder().decode(BackupRulesProbe.self, from: json)
        XCTAssertNil(document.sensitiveRules)
    }
}

/// Mirrors the optional `sensitiveRules` key on the backup document.
private struct BackupRulesProbe: Decodable {
    var sensitiveRules: [SensitiveRuleBackup]?
}
