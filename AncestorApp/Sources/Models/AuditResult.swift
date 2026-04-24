import Foundation

/// An audit finding — error, warning, or info.
struct AuditResult: Codable, Identifiable, Sendable {
    let id: UUID
    let profileID: String
    let profileName: String
    let severity: Severity
    let ruleID: String
    let message: String
}

enum Severity: String, Codable, Sendable {
    case error, warning, info
}
