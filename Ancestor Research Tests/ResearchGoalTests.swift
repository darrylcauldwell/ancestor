import Testing
import Foundation
@testable import Ancestor_Research

/// M13 — research goals (per DESIGN.md §5.16). Foundation tests for the
/// DB layer (CRUD round-trip, status enum coverage). View-level tests are
/// out of scope per project conventions.
struct ResearchGoalTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeGoal(
        id: UUID = UUID(),
        title: String = "Trace maternal line to the 1700s",
        description: String? = nil,
        status: GoalStatus = .active,
        progress: Int = 0,
        questionIDs: [UUID] = [],
        hypothesisIDs: [UUID] = [],
        focusSetID: UUID? = nil,
        completedAt: Date? = nil
    ) -> ResearchGoal {
        ResearchGoal(
            id: id, title: title, description: description,
            status: status, progress: progress,
            questionIDs: questionIDs, hypothesisIDs: hypothesisIDs,
            focusSetID: focusSetID,
            createdAt: Date(),
            completedAt: completedAt
        )
    }

    @Test func addingGoalPersists() throws {
        let db = try makeTempDB()
        let goal = makeGoal(title: "Find William Land's father")
        try db.addResearchGoal(goal)

        let loaded = try db.loadResearchGoals()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Find William Land's father")
        #expect(loaded.first?.id == goal.id)
        #expect(loaded.first?.status == .active)
        #expect(loaded.first?.progress == 0)
    }

    @Test func updatingGoalRoundTripsAllFields() throws {
        let db = try makeTempDB()
        let original = makeGoal(title: "Initial title")
        try db.addResearchGoal(original)

        let q1 = UUID(), q2 = UUID()
        let h1 = UUID()
        let focusID = UUID()
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)

        var updated = original
        updated.title = "Trace paternal line to 1750"
        updated.description = "Stuck on James Smith born ABT 1820"
        updated.status = .completed
        updated.progress = 100
        updated.questionIDs = [q1, q2]
        updated.hypothesisIDs = [h1]
        updated.focusSetID = focusID
        updated.completedAt = completedAt
        try db.updateResearchGoal(updated)

        let reloaded = try db.loadResearchGoals().first
        #expect(reloaded?.title == "Trace paternal line to 1750")
        #expect(reloaded?.description == "Stuck on James Smith born ABT 1820")
        #expect(reloaded?.status == .completed)
        #expect(reloaded?.progress == 100)
        #expect(reloaded?.questionIDs == [q1, q2])
        #expect(reloaded?.hypothesisIDs == [h1])
        #expect(reloaded?.focusSetID == focusID)
        // SQLite datetime round-trips to second precision — within 1s is fine.
        if let loadedCompleted = reloaded?.completedAt {
            #expect(abs(loadedCompleted.timeIntervalSince(completedAt)) < 1.0)
        } else {
            Issue.record("completedAt did not round-trip")
        }
    }

    @Test func deletingGoalRemovesIt() throws {
        let db = try makeTempDB()
        let g1 = makeGoal(title: "Goal A")
        let g2 = makeGoal(title: "Goal B")
        try db.addResearchGoal(g1)
        try db.addResearchGoal(g2)
        #expect(try db.loadResearchGoals().count == 2)

        try db.deleteResearchGoal(id: g1.id)
        let remaining = try db.loadResearchGoals()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == g2.id)
    }

    @Test func goalStatusEnumCoversFourCases() {
        let cases = GoalStatus.allCases
        #expect(cases.count == 4)
        #expect(cases.contains(.active))
        #expect(cases.contains(.paused))
        #expect(cases.contains(.completed))
        #expect(cases.contains(.abandoned))
        // Display names are non-empty so list rows always have a label.
        for status in cases {
            #expect(!status.displayName.isEmpty)
        }
    }

    @Test func progressRoundTripsIntegerValues() throws {
        let db = try makeTempDB()
        for value in [0, 50, 100] {
            let goal = makeGoal(title: "Progress \(value)", progress: value)
            try db.addResearchGoal(goal)
        }
        let loaded = try db.loadResearchGoals()
        #expect(loaded.count == 3)
        let progressValues = Set(loaded.map(\.progress))
        #expect(progressValues == Set([0, 50, 100]))
    }

    @Test func emptyArraysRoundTrip() throws {
        let db = try makeTempDB()
        let goal = makeGoal()
        try db.addResearchGoal(goal)
        let reloaded = try db.loadResearchGoals().first
        #expect(reloaded?.questionIDs == [])
        #expect(reloaded?.hypothesisIDs == [])
        #expect(reloaded?.focusSetID == nil)
        #expect(reloaded?.completedAt == nil)
        #expect(reloaded?.description == nil)
    }
}
