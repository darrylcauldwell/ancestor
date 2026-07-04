import Foundation

/// A structured research todo — something the user is trying to figure out.
/// The crucial field is `triedSources`: recording dead ends turns wasted
/// effort into useful information. Genealogists waste enormous time
/// re-searching sources they've already checked.
nonisolated struct OpenQuestion: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var text: String                    // "Who were William Land's parents?"
    var profileIDs: [String]            // Profiles this question relates to
    var priority: QuestionPriority
    var status: QuestionStatus
    var triedSources: String?           // "FreeBMD 1810-1820, nothing. Wirksworth 1815, no match."
    var promotedFrom: QuestionOrigin?   // Provenance — for context, not enforcement
    var createdAt: Date
    var resolvedAt: Date?
    var resolution: String?             // How it was answered, if resolved
}

nonisolated enum QuestionPriority: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Numeric weight for sorting — high first.
    var sortWeight: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

nonisolated enum QuestionStatus: String, Codable, CaseIterable, Sendable {
    case open, inProgress, blocked, resolved

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .blocked: return "Blocked"
        case .resolved: return "Resolved"
        }
    }

    /// Group order in the questions list — open first, resolved last.
    var groupOrder: Int {
        switch self {
        case .open: return 0
        case .inProgress: return 1
        case .blocked: return 2
        case .resolved: return 3
        }
    }
}

/// Where a question originated — for provenance, not enforcement.
nonisolated enum QuestionOrigin: Codable, Hashable, Sendable {
    case manual
    case fromAudit(ruleID: String)
    case fromGap(profileID: String, field: ProfileField)
    case fromResearch(hypothesisID: UUID)
}
