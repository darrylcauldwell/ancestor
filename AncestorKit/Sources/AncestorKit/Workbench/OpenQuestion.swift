import Foundation

/// A structured research todo — something the user is trying to figure out.
/// The crucial field is `triedSources`: recording dead ends turns wasted
/// effort into useful information. Genealogists waste enormous time
/// re-searching sources they've already checked.
public nonisolated struct OpenQuestion: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var text: String                    // "Who were William Land's parents?"
    public var profileIDs: [String]            // Profiles this question relates to
    public var priority: QuestionPriority
    public var status: QuestionStatus
    public var triedSources: String?           // "FreeBMD 1810-1820, nothing. Wirksworth 1815, no match."
    public var promotedFrom: QuestionOrigin?   // Provenance — for context, not enforcement
    public var createdAt: Date
    public var resolvedAt: Date?
    public var resolution: String?             // How it was answered, if resolved

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, text: String, profileIDs: [String], priority: QuestionPriority, status: QuestionStatus, triedSources: String? = nil, promotedFrom: QuestionOrigin? = nil, createdAt: Date, resolvedAt: Date? = nil, resolution: String? = nil) {
        self.id = id
        self.text = text
        self.profileIDs = profileIDs
        self.priority = priority
        self.status = status
        self.triedSources = triedSources
        self.promotedFrom = promotedFrom
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.resolution = resolution
    }

}

public nonisolated enum QuestionPriority: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Numeric weight for sorting — high first.
    public var sortWeight: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

public nonisolated enum QuestionStatus: String, Codable, CaseIterable, Sendable {
    case open, inProgress, blocked, resolved

    public var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .blocked: return "Blocked"
        case .resolved: return "Resolved"
        }
    }

    /// Group order in the questions list — open first, resolved last.
    public var groupOrder: Int {
        switch self {
        case .open: return 0
        case .inProgress: return 1
        case .blocked: return 2
        case .resolved: return 3
        }
    }
}

/// Where a question originated — for provenance, not enforcement.
public nonisolated enum QuestionOrigin: Codable, Hashable, Sendable {
    case manual
    case fromAudit(ruleID: String)
    case fromGap(profileID: String, field: ProfileField)
    case fromResearch(hypothesisID: UUID)
}
