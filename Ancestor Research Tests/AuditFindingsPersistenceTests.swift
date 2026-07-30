import Testing
import Foundation
@testable import Ancestor_Research
import AncestorKit

/// v55 `audit_findings` persistence (MCP_CONSUMER_SURFACE_SPEC MC4):
/// replace-snapshot write + all/per-profile reads, so an external MCP server
/// can read Health audit findings with an honest `computed_at`.
struct AuditFindingsPersistenceTests {

    private func makeTempDB() throws -> ProjectDatabase {
        try ProjectDatabase(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func result(
        profileID: String, ruleID: String,
        severity: Severity = .warning, message: String = "message"
    ) -> AuditResult {
        AuditResult(
            profileID: profileID, profileName: "Test Person",
            severity: severity, ruleID: ruleID, message: message)
    }

    @Test func roundTripReplaceAndReadAllAndPerProfile() throws {
        let db = try makeTempDB()
        try db.replaceAuditFindings([
            result(profileID: "p1", ruleID: "birth_before_death", severity: .error, message: "Born after death"),
            result(profileID: "p2", ruleID: "no_birth_date", severity: .warning, message: "No birth date"),
            result(profileID: "", ruleID: "tree_disconnected", severity: .info, message: "Tree has 2 islands")
        ])

        let all = try db.latestAuditFindings()
        #expect(all.count == 3)
        // Severity ordering: errors first, info last.
        #expect(all.first?.severity == .error)
        #expect(all.last?.severity == .info)
        // Field mapping survives the round trip.
        let error = try #require(all.first)
        #expect(error.ruleID == "birth_before_death")
        #expect(error.profileID == "p1")
        #expect(error.message == "Born after death")
        // Tree-level finding (empty profileID) is stored as NULL.
        #expect(all.last?.profileID == nil)

        // Per-profile filter returns only that profile's findings.
        let p1 = try db.latestAuditFindings(profileID: "p1")
        #expect(p1.count == 1)
        #expect(p1.first?.ruleID == "birth_before_death")
        let p2 = try db.latestAuditFindings(profileID: "p2")
        #expect(p2.count == 1)
        #expect(p2.first?.severity == .warning)
        #expect(try db.latestAuditFindings(profileID: "nobody").isEmpty)
    }

    @Test func replaceClearsPriorSnapshot() throws {
        let db = try makeTempDB()
        try db.replaceAuditFindings([
            result(profileID: "p1", ruleID: "rule_a"),
            result(profileID: "p2", ruleID: "rule_b")
        ])
        try db.replaceAuditFindings([
            result(profileID: "p3", ruleID: "rule_c")
        ])

        let all = try db.latestAuditFindings()
        #expect(all.count == 1)
        #expect(all.first?.ruleID == "rule_c")
        #expect(try db.latestAuditFindings(profileID: "p1").isEmpty)

        // An empty snapshot legitimately clears the table.
        try db.replaceAuditFindings([])
        #expect(try db.latestAuditFindings().isEmpty)
    }

    @Test func computedAtSurvivesRoundTrip() throws {
        let db = try makeTempDB()
        let computedAt = Date(timeIntervalSince1970: 1_753_000_000) // fixed, sub-second-free
        try db.replaceAuditFindings(
            [result(profileID: "p1", ruleID: "rule_a")],
            computedAt: computedAt)

        let stored = try #require(try db.latestAuditFindings().first)
        // GRDB stores datetimes at millisecond precision — compare within that.
        #expect(abs(stored.computedAt.timeIntervalSince(computedAt)) < 0.01)
    }
}
