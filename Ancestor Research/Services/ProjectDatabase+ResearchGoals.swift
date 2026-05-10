import Foundation
import GRDB

/// Research goal persistence (M13). Per DESIGN.md §5.16.
nonisolated extension ProjectDatabase {

    @discardableResult
    func addResearchGoal(_ goal: ResearchGoal) throws -> ResearchGoal {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO research_goals
                  (id, title, description, status, progress,
                   question_ids_json, hypothesis_ids_json, focus_set_id,
                   created_at, completed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    goal.id.uuidString, goal.title, goal.description,
                    goal.status.rawValue, goal.progress,
                    Self.encodeJSON(goal.questionIDs),
                    Self.encodeJSON(goal.hypothesisIDs),
                    goal.focusSetID?.uuidString,
                    goal.createdAt, goal.completedAt,
                ])
        }
        return goal
    }

    @discardableResult
    func updateResearchGoal(_ goal: ResearchGoal) throws -> ResearchGoal {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE research_goals
                SET title = ?, description = ?, status = ?, progress = ?,
                    question_ids_json = ?, hypothesis_ids_json = ?,
                    focus_set_id = ?, completed_at = ?
                WHERE id = ?
                """, arguments: [
                    goal.title, goal.description, goal.status.rawValue, goal.progress,
                    Self.encodeJSON(goal.questionIDs),
                    Self.encodeJSON(goal.hypothesisIDs),
                    goal.focusSetID?.uuidString,
                    goal.completedAt,
                    goal.id.uuidString,
                ])
        }
        return goal
    }

    func deleteResearchGoal(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM research_goals WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    func loadResearchGoals() throws -> [ResearchGoal] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM research_goals ORDER BY created_at DESC
                """)
            return rows.compactMap(Self.researchGoalFromRow)
        }
    }

    static func researchGoalFromRow(_ row: Row) -> ResearchGoal? {
        guard
            let idStr: String = row["id"], let id = UUID(uuidString: idStr),
            let title: String = row["title"],
            let statusStr: String = row["status"],
            let status = GoalStatus(rawValue: statusStr),
            let progress: Int = row["progress"],
            let qJSON: String = row["question_ids_json"],
            let qData = qJSON.data(using: .utf8),
            let questionIDs = try? JSONDecoder().decode([UUID].self, from: qData),
            let hJSON: String = row["hypothesis_ids_json"],
            let hData = hJSON.data(using: .utf8),
            let hypothesisIDs = try? JSONDecoder().decode([UUID].self, from: hData),
            let createdAt: Date = row["created_at"]
        else { return nil }
        let focusSetIDStr: String? = row["focus_set_id"]
        let focusSetID = focusSetIDStr.flatMap(UUID.init(uuidString:))
        return ResearchGoal(
            id: id, title: title,
            description: row["description"],
            status: status, progress: progress,
            questionIDs: questionIDs,
            hypothesisIDs: hypothesisIDs,
            focusSetID: focusSetID,
            createdAt: createdAt,
            completedAt: row["completed_at"]
        )
    }
}
