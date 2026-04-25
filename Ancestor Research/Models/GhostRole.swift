import Foundation

/// Role of an unknown ancestor — shared by TreeLayout (ghost nodes) and Research (subject construction).
/// Defined once here, consumed by both systems.
nonisolated enum GhostRole: String, Codable, Sendable {
    case father, mother, unknown
}
