import Foundation

/// Long-term research objective grouping workbench items. Higher level than
/// open questions — goals organise work over months and years. Per DESIGN.md §5.16.
nonisolated struct ResearchGoal: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var title: String                       // "Trace maternal line to the 1700s"
    var description: String?
    var status: GoalStatus
    var progress: Int                       // 0-100, user-assessed (not auto-calculated)
    var questionIDs: [UUID]                 // Open questions in service of this goal
    var hypothesisIDs: [UUID]               // Hypotheses related to this goal
    var focusSetID: UUID?                   // Focus set used when working on this goal
    var createdAt: Date
    var completedAt: Date?
}

nonisolated enum GoalStatus: String, Codable, CaseIterable, Sendable {
    case active, paused, completed, abandoned

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .abandoned: return "Abandoned"
        }
    }
}
