import Foundation

/// User-asserted confidence on a committed fact (DESIGN.md §5.14). Distinct
/// from `EvidenceQuality` (which rates the source) and from `FieldDispute`
/// (which is between sources). This is the user saying "I committed this
/// but I'm watching it."
///
/// Applied to `FieldSource` (per profile field) and `LifeEvent`.
/// `.standard` is default — users only change it when they want to signal
/// something.
nonisolated enum FactConfidence: String, Codable, CaseIterable, Sendable {
    case tentative          // "Committed but watching" — needs more evidence
    case standard           // Default
    case wellEvidenced      // Multiple independent sources agree

    var displayName: String {
        switch self {
        case .tentative: return "Tentative"
        case .standard: return "Standard"
        case .wellEvidenced: return "Well evidenced"
        }
    }

    var explanation: String {
        switch self {
        case .tentative: return "Committed but watching for more evidence."
        case .standard: return "Default confidence — no special assertion."
        case .wellEvidenced: return "Multiple independent sources agree."
        }
    }

    /// Numeric integer for cheap DB storage. Matches GEDCOM-style 0/1/2.
    var rawInt: Int {
        switch self {
        case .tentative: return 0
        case .standard: return 1
        case .wellEvidenced: return 2
        }
    }

    init?(rawInt: Int) {
        switch rawInt {
        case 0: self = .tentative
        case 1: self = .standard
        case 2: self = .wellEvidenced
        default: return nil
        }
    }
}
