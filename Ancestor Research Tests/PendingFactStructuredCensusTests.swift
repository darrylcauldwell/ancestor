import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// #24 — structured census context on MCP submissions. A hand-searched
/// census accepted through the firewall used to land as PROSE: readable by
/// the human, invisible to the family-context gate, the cite machinery and
/// the ledger (owner dogfood 2026-08-24: the 1891 FreeCEN and 1901
/// FamilySearch censuses side by side on Ernest Cauldwell's profile — one a
/// structured roster, one a text blob). The submission's `household` now
/// rides the routing payload and the accept path projects it into typed
/// census details PLUS a first-class census evidence record.
@MainActor
struct PendingFactStructuredCensusTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        let ernest = Profile(id: "ernest", externalIDs: [:], firstName: "Ernest", middleName: nil,
                             lastName: "Cauldwell", gender: .male, isDeleted: false,
                             sources: [:], disputes: [:])
        _ = try db.addProfile(ernest, source: SourceOrigin(identifier: "test"))
        return db
    }

    private func payloadJSON(withHousehold: Bool) -> String {
        var payload: [String: Any] = [
            "event_date": "1901",
            "event_location": "Turnditch, Derbyshire",
            "district": "Belper",
            "parish": "Turnditch",
        ]
        if withHousehold {
            payload["household"] = [
                ["name": "John Cauldwell", "relationship": "Head", "age": 39, "birth_place": "Windley", "occupation": "Agri Lab"],
                ["name": "Elizabeth Cauldwell", "relationship": "Wife", "age": 39],
                ["name": "Martha Barker", "relationship": "Ma-Law", "age": 76, "marital_status": "W"],
                ["name": "Ernest Cauldwell", "relationship": "Son", "age": 13, "birth_place": "Turnditch"],
                ["name": "", "relationship": "Son"],   // malformed — dropped, not fatal
            ]
        }
        return String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    }

    @Test func structuredHouseholdProjectsTypedDetailsAndEvidence() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census",
            value: "1901 census, Turnditch: Ernest in his parents' household",
            payloadJSON: payloadJSON(withHousehold: true),
            sourceTitle: "1901 census: John Cauldwell household, Turnditch",
            sourceURL: "https://www.familysearch.org/ark:/61903/1:1:p_test")

        // Life event carries TYPED census details, not just prose.
        let event = try #require(try db.loadLifeEvents(profileID: "ernest")
            .first { $0.type == .census })
        guard case .census(let details)? = event.details else {
            Issue.record("expected typed census details, got \(String(describing: event.details))")
            return
        }
        #expect(details.household.count == 4, "malformed nameless member dropped")
        #expect(details.district == "Belper")
        #expect(details.parish == "Turnditch")
        let ernestRow = try #require(details.household.first { $0.name == "Ernest Cauldwell" })
        #expect(ernestRow.isTarget == true, "the subject's own row is marked, as app-fetched rosters do")
        #expect(details.household.first { $0.name == "Martha Barker" }?.maritalStatus == "W")
        #expect(event.sources.contains { $0.citation?.url?.contains("p_test") == true })

        // …and a first-class census EVIDENCE record exists with the roster —
        // what the ledger, family gate and cite machinery read.
        let evidence = try db.loadEvidenceForProfile("ernest")
        let census = try #require(evidence.first { $0.recordType == .census })
        guard case .census(let rec) = census.record else {
            Issue.record("expected census record"); return
        }
        #expect(rec.censusYear == 1901)
        #expect(rec.household?.count == 4)
        #expect(census.userStatus == .savedAsLead)
        #expect(census.wasApplied(to: nil) == false || census.userStatus == .savedAsLead)
    }

    @Test func proseOnlySubmissionStillLandsAsBefore() throws {
        let db = try makeDB()
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census",
            value: "1901 census, Turnditch (prose only)",
            payloadJSON: payloadJSON(withHousehold: false),
            sourceTitle: "t", sourceURL: "https://example.org/x")
        let event = try #require(try db.loadLifeEvents(profileID: "ernest")
            .first { $0.type == .census })
        #expect(event.details == nil, "no household submitted → no invented details")
        #expect(try db.loadEvidenceForProfile("ernest").isEmpty,
                "no roster → no synthetic evidence record")
    }

    @Test func resubmissionGraftsDetailsOntoAProseEvent() throws {
        // The backfill path: a prose census accepted BEFORE #24 gets a
        // structured resubmission — same (profile, type, date, value)
        // fingerprint — and the details are grafted, never duplicated.
        let db = try makeDB()
        let value = "1901 census, Turnditch: Ernest in his parents' household"
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: payloadJSON(withHousehold: false),
            sourceTitle: "t", sourceURL: "https://example.org/x")
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: payloadJSON(withHousehold: true),
            sourceTitle: "t", sourceURL: "https://example.org/x")
        let events = try db.loadLifeEvents(profileID: "ernest").filter { $0.type == .census }
        #expect(events.count == 1, "same fingerprint → one event, never a duplicate")
        guard case .census(let details)? = events.first?.details else {
            Issue.record("details not grafted onto the existing prose event"); return
        }
        #expect(details.household.count == 4)
    }

    @Test func householdParserMarksTargetAndTolerates() {
        let payload: [String: Any] = ["household": [
            ["name": "William GOODLAD", "relationship": "Son", "age": 15],
            ["name": "Ellen Goodlad", "relationship": "Head"],
            ["relationship": "Dau"],                        // nameless — dropped
            ["name": "Lodger Person", "relationship": ""],  // roleless — dropped
        ]]
        let members = ProjectDatabase.pendingFactHousehold(
            payload: payload, subjectName: "William Goodlad")
        #expect(members.count == 2)
        #expect(members.first { $0.name == "William GOODLAD" }?.isTarget == true)
        #expect(members.first { $0.name == "Ellen Goodlad" }?.isTarget == nil)
    }
}
