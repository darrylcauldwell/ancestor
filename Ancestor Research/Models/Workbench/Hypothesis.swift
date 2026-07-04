import Foundation

/// A tentative claim — something the user believes but hasn't committed
/// as a fact. The tree data model has only "confirmed or absent"; real
/// research lives in the middle, and that's what this represents.
nonisolated struct Hypothesis: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var claim: HypothesisClaim
    var confidence: HypothesisConfidence
    var reasoning: String
    var supportingEvidence: [String]
    var contradictingEvidence: [String]
    var status: HypothesisStatus
    var createdAt: Date
    var resolvedAt: Date?
    var dismissalReason: String?

    /// One-line human-readable claim. Used in lists and the tree popover.
    var claimSummary: String {
        switch claim {
        case .relationship(_, _, let type, let role):
            switch type {
            case .parent:
                let r = role.map { " (\($0.rawValue))" } ?? ""
                return "Parent\(r) relationship"
            case .spouse:
                return "Spouse relationship"
            }
        case .fieldValue(_, let field, let value):
            return "\(field.rawValue) = \"\(value)\""
        case .identityMatch:
            return "Identity match"
        case .existence(let description, _):
            return description
        }
    }
}

/// Four claim types cover the shapes of genealogical guessing.
nonisolated enum HypothesisClaim: Codable, Hashable, Sendable {
    case relationship(fromID: String, toID: String, type: RelationshipType, role: ParentRole?)
    case fieldValue(profileID: String, field: ProfileField, value: String)
    case identityMatch(profileID1: String, profileID2: String)
    case existence(description: String, relatedProfileIDs: [String])

    /// Discriminator used by lists, filters, and the tree uncertainty layer.
    var kind: Kind {
        switch self {
        case .relationship: return .relationship
        case .fieldValue: return .fieldValue
        case .identityMatch: return .identityMatch
        case .existence: return .existence
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case relationship, fieldValue, identityMatch, existence

        var displayName: String {
            switch self {
            case .relationship: return "Relationship"
            case .fieldValue: return "Field value"
            case .identityMatch: return "Identity match"
            case .existence: return "Existence"
            }
        }
    }
}

nonisolated enum HypothesisConfidence: String, Codable, CaseIterable, Sendable {
    case speculation       // "Maybe" — just an idea worth tracking
    case working           // "Probably" — actively investigating
    case strong            // "Almost certain" — ready to promote

    var displayName: String {
        switch self {
        case .speculation: return "Speculation"
        case .working: return "Working"
        case .strong: return "Strong"
        }
    }

    /// Group order in the list — strong first, speculation last.
    var groupOrder: Int {
        switch self {
        case .strong: return 0
        case .working: return 1
        case .speculation: return 2
        }
    }
}

nonisolated enum HypothesisStatus: String, Codable, CaseIterable, Sendable {
    case active            // Under investigation
    case promoted          // Resolved → committed as fact
    case dismissed         // Resolved → rejected, reason preserved
    case superseded        // Replaced by a better hypothesis

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .promoted: return "Promoted"
        case .dismissed: return "Dismissed"
        case .superseded: return "Superseded"
        }
    }

    var isResolved: Bool { self != .active }
}
