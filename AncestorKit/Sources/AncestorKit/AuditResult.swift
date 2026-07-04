import Foundation

/// An audit finding — error, warning, or info.
public nonisolated struct AuditResult: Codable, Identifiable, Sendable {
    public let id: UUID
    public let profileID: String
    public let profileName: String
    public let severity: Severity
    public let category: AuditCategory
    public let ruleID: String
    public let message: String

    /// Optional alternate message used in manual-guidance mode (M16.6).
    /// When `AppState.isSmallManualProject` is true, callers should prefer
    /// this over `message`. Nil for rules that have no guidance variant
    /// (errors stay as errors even in guidance mode).
    public var guidanceMessage: String?

    /// Other profile IDs implicated by this finding (M19). For
    /// `DuplicateDetectionRule` this carries the candidate's ID so the
    /// Tasks view can offer "Compare" without scraping the message.
    /// Nil for rules that don't reference a second profile.
    public var relatedProfileIDs: [String]?

    /// Convenience init with default category = .issue (backward compatible).
    public init(id: UUID = UUID(), profileID: String, profileName: String,
         severity: Severity, category: AuditCategory = .issue,
         ruleID: String, message: String, guidanceMessage: String? = nil,
         relatedProfileIDs: [String]? = nil) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.severity = severity
        self.category = category
        self.ruleID = ruleID
        self.message = message
        self.guidanceMessage = guidanceMessage
        self.relatedProfileIDs = relatedProfileIDs
    }
}

public nonisolated enum Severity: String, Codable, Sendable {
    case error, warning, info
}

/// Audit results fall into two categories:
/// - Issues: data consistency problems (birth before death, impossible ages)
/// - Gaps: missing data that could be researched (no birth date, no parents)
public nonisolated enum AuditCategory: String, Codable, Sendable {
    case issue      // Logic/consistency errors — data is wrong
    case gap        // Missing data — data is absent
}
