import Foundation

/// Long-term research objective grouping workbench items. Higher level than
/// open questions — goals organise work over months and years. Per DESIGN.md §5.16.
public nonisolated struct ResearchGoal: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var title: String                       // "Trace maternal line to the 1700s"
    public var description: String?
    public var status: GoalStatus
    public var progress: Int                       // 0-100, user-assessed (not auto-calculated)
    public var questionIDs: [UUID]                 // Open questions in service of this goal
    public var hypothesisIDs: [UUID]               // Hypotheses related to this goal
    public var focusSetID: UUID?                   // Focus set used when working on this goal
    public var createdAt: Date
    public var completedAt: Date?

    /// Public memberwise init — synthesized inits are internal
    /// outside the package, so cross-module construction needs this.
    public init(id: UUID, title: String, description: String? = nil, status: GoalStatus, progress: Int, questionIDs: [UUID], hypothesisIDs: [UUID], focusSetID: UUID? = nil, createdAt: Date, completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.progress = progress
        self.questionIDs = questionIDs
        self.hypothesisIDs = hypothesisIDs
        self.focusSetID = focusSetID
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

}

public nonisolated enum GoalStatus: String, Codable, CaseIterable, Sendable {
    case active, paused, completed, abandoned

    public var displayName: String {
        switch self {
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .abandoned: return "Abandoned"
        }
    }
}
