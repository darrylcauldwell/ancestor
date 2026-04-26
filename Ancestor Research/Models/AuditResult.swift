import Foundation

/// An audit finding — error, warning, or info.
nonisolated struct AuditResult: Codable, Identifiable, Sendable {
    let id: UUID
    let profileID: String
    let profileName: String
    let severity: Severity
    let category: AuditCategory
    let ruleID: String
    let message: String

    /// Convenience init with default category = .issue (backward compatible).
    init(id: UUID = UUID(), profileID: String, profileName: String,
         severity: Severity, category: AuditCategory = .issue,
         ruleID: String, message: String) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.severity = severity
        self.category = category
        self.ruleID = ruleID
        self.message = message
    }
}

nonisolated enum Severity: String, Codable, Sendable {
    case error, warning, info
}

/// Audit results fall into two categories:
/// - Issues: data consistency problems (birth before death, impossible ages)
/// - Gaps: missing data that could be researched (no birth date, no parents)
nonisolated enum AuditCategory: String, Codable, Sendable {
    case issue      // Logic/consistency errors — data is wrong
    case gap        // Missing data — data is absent
}
