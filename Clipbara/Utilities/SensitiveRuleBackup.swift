import Foundation

/// A sensitive-app rule as stored in a JSON backup.
///
/// These are match patterns (bundle id, process name, or site), not clipboard
/// contents. Clip payloads stay out of backups because they are encrypted with
/// a device key and meant to auto-erase. The rules themselves have to travel
/// with the backup, or the next copy from a password manager is stored in
/// plaintext on the destination.
struct SensitiveRuleBackup: Codable, Equatable, Sendable {
    var kind: String
    var pattern: String
    var displayName: String
}

enum SensitiveRuleBackupMerge {

    /// Rules from `incoming` that are not already in `existing`.
    ///
    /// Unknown kinds and blank patterns are dropped. Process names and domains
    /// compare case-insensitively, matching the settings UI. Domain patterns
    /// are stored lowercased, which is how they are recorded when added.
    static func rulesToImport(
        existing: [SensitiveRuleBackup],
        incoming: [SensitiveRuleBackup]
    ) -> [SensitiveRuleBackup] {
        var seen = Set(existing.compactMap { identity(of: $0) })
        var result: [SensitiveRuleBackup] = []
        for rule in incoming {
            guard let normalized = normalize(rule), let key = identity(of: normalized) else { continue }
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func normalize(_ rule: SensitiveRuleBackup) -> SensitiveRuleBackup? {
        guard rule.kind == "app" || rule.kind == "process" || rule.kind == "domain" else { return nil }
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        let storedPattern = rule.kind == "domain" ? pattern.lowercased() : pattern
        let name = rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return SensitiveRuleBackup(
            kind: rule.kind,
            pattern: storedPattern,
            displayName: name.isEmpty ? storedPattern : name
        )
    }

    private static func identity(of rule: SensitiveRuleBackup) -> String? {
        switch rule.kind {
        case "app":
            return "app:\(rule.pattern)"
        case "process":
            return "process:\(rule.pattern.lowercased())"
        case "domain":
            return "domain:\(rule.pattern.lowercased())"
        default:
            return nil
        }
    }
}
