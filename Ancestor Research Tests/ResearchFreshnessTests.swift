import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// Health "research freshness" feed (2026-07-30): latest research
/// completion per profile from research_runs; a profile with no runs is
/// absent from the map (= never researched).
struct ResearchFreshnessTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    @Test func latestCompletionPerProfileWins() throws {
        let db = try makeTempDB()
        let old = Date(timeIntervalSinceNow: -100 * 86_400)
        let recent = Date(timeIntervalSinceNow: -5 * 86_400)
        try db.saveResearchRun(
            id: UUID(), profileID: "p1", mode: .adaptive,
            startedAt: old, completedAt: old,
            factCount: 1, leadCount: 0, clusterCount: 1, gpsScore: nil)
        try db.saveResearchRun(
            id: UUID(), profileID: "p1", mode: .adaptive,
            startedAt: recent, completedAt: recent,
            factCount: 2, leadCount: 1, clusterCount: 1, gpsScore: 3)
        try db.saveResearchRun(
            id: UUID(), profileID: "p2", mode: .verify,
            startedAt: old, completedAt: old,
            factCount: 0, leadCount: 0, clusterCount: 0, gpsScore: nil)

        let map = try db.lastResearchCompletions()
        #expect(map.count == 2)
        #expect(abs(map["p1"]!.timeIntervalSince(recent)) < 2, "latest run wins")
        #expect(abs(map["p2"]!.timeIntervalSince(old)) < 2)
        #expect(map["never-researched"] == nil, "absent key = never researched")
    }
}
