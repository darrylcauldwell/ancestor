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

    // MARK: - #27 citation URL correction

    @Test func correctedResubmissionReplacesStaleCitationURL() throws {
        // Owner dogfood 2026-08-24: FS search-persona ark URLs 404 in a
        // browser. A resubmission of the SAME fact (same origin, same title)
        // with the repaired URL must replace the dead citation — appending
        // would leave a dead link posing as a second source.
        let db = try makeDB()
        let value = "1901 census, Turnditch: Ernest in his parents' household"
        let title = "1901 census: John Cauldwell household, Turnditch"
        let deadURL = "https://www.familysearch.org/ark:/61903/1:1:p_10268848273#structured"
        let realURL = "https://www.familysearch.org/ark:/61903/1:1:XSJJ-LD6"
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: payloadJSON(withHousehold: true),
            sourceTitle: title, sourceURL: deadURL)
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: payloadJSON(withHousehold: true),
            sourceTitle: title, sourceURL: realURL)

        let events = try db.loadLifeEvents(profileID: "ernest").filter { $0.type == .census }
        #expect(events.count == 1)
        let cited = events.first?.sources.filter { $0.origin.identifier == "field-researcher" } ?? []
        #expect(cited.count == 1, "stale citation replaced, not accumulated")
        #expect(cited.first?.citation?.url == realURL)

        // The census EVIDENCE record re-upserts under the same composite id,
        // so its detail URL is corrected too.
        let evidence = try db.loadEvidenceForProfile("ernest")
        let census = try #require(evidence.first { $0.recordType == .census })
        guard case .census(let rec) = census.record else {
            Issue.record("expected census record"); return
        }
        #expect(rec.common.detailURL == realURL)
    }

    @Test func differentTitledCitationIsCorroborationNotCorrection() throws {
        // Same event corroborated by a genuinely different source (different
        // title, different URL) keeps BOTH citations.
        let db = try makeDB()
        let value = "1901 census, Turnditch: Ernest in his parents' household"
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: payloadJSON(withHousehold: false),
            sourceTitle: "1901 census: John Cauldwell household, Turnditch",
            sourceURL: "https://www.familysearch.org/ark:/61903/1:1:XSJJ-LD6")
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: payloadJSON(withHousehold: false),
            sourceTitle: "FreeCEN transcript: Turnditch 1901",
            sourceURL: "https://www.freecen.org.uk/search_records/xyz")
        let event = try #require(try db.loadLifeEvents(profileID: "ernest")
            .first { $0.type == .census })
        #expect(event.sources.count == 2, "corroborating source appended, correction not triggered")
    }

    @Test func provenanceRowURLCorrectionUpdatesInPlace() throws {
        // The profile-column path's field_sources row: a corrected
        // resubmission updates citation_json on the existing row instead of
        // stacking a second row that keeps the dead link alive.
        let db = try makeDB()
        try db.addAcceptedFactProvenance(
            profileID: "ernest", field: "birthDate", value: "1887",
            sourceTitle: "GRO index via FamilySearch",
            sourceURL: "https://www.familysearch.org/ark:/61903/1:1:p_123")
        try db.addAcceptedFactProvenance(
            profileID: "ernest", field: "birthDate", value: "1887",
            sourceTitle: "GRO index via FamilySearch",
            sourceURL: "https://www.familysearch.org/ark:/61903/1:1:REAL-ARK")
        let (count, json): (Int, String) = try db.dbQueue.read { sql in
            let n = try Int.fetchOne(sql, sql: """
                SELECT COUNT(*) FROM field_sources
                WHERE entity_id = 'ernest' AND field = 'birthDate'
                """) ?? -1
            let j = try String.fetchOne(sql, sql: """
                SELECT citation_json FROM field_sources
                WHERE entity_id = 'ernest' AND field = 'birthDate'
                """) ?? ""
            return (n, j)
        }
        #expect(count == 1, "same-host URL repair updates in place, never stacks")
        #expect(json.contains("REAL-ARK"))
        #expect(!json.contains("p_123"))

        // The journal contract is untouched: an IDENTICAL re-accept still
        // appends a second attestation row (ledger collapses, bin removes one).
        try db.addAcceptedFactProvenance(
            profileID: "ernest", field: "birthDate", value: "1887",
            sourceTitle: "GRO index via FamilySearch",
            sourceURL: "https://www.familysearch.org/ark:/61903/1:1:REAL-ARK")
        let after = try db.dbQueue.read { sql in
            try Int.fetchOne(sql, sql: """
                SELECT COUNT(*) FROM field_sources
                WHERE entity_id = 'ernest' AND field = 'birthDate'
                """) ?? -1
        }
        #expect(after == 2, "identical accepts append — the journal is preserved")

        // A corroborating source on a DIFFERENT host is never rewritten.
        try db.addAcceptedFactProvenance(
            profileID: "ernest", field: "birthDate", value: "1887",
            sourceTitle: "GRO index via FamilySearch",
            sourceURL: "https://www.freebmd.org.uk/cgi/information.pl?r=123")
        let hosts = try db.dbQueue.read { sql in
            try String.fetchAll(sql, sql: """
                SELECT citation_json FROM field_sources
                WHERE entity_id = 'ernest' AND field = 'birthDate'
                """)
        }
        #expect(hosts.count == 3)
        #expect(hosts.filter { $0.contains("REAL-ARK") }.count == 2)
        #expect(hosts.contains { $0.contains("freebmd.org.uk") })
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

    // MARK: - #28 married-surname target matching

    @Test func marriedWomanIsMarkedTargetUnderHerMarriedSurname() {
        // Tree stores Ruth under maiden BRAILSFORD; the census schedule says
        // Ruth WHEELDON. The suffix match must accept either surname.
        let payload: [String: Any] = ["household": [
            ["name": "John Wheeldon", "relationship": "Head"],
            ["name": "Ruth Wheeldon", "relationship": "Wife"],
        ]]
        let members = ProjectDatabase.pendingFactHousehold(
            payload: payload, subjectName: "Ruth Brailsford",
            subjectMarriedSurname: "Wheeldon")
        #expect(members.first { $0.name == "Ruth Wheeldon" }?.isTarget == true)
        #expect(members.first { $0.name == "John Wheeldon" }?.isTarget == nil,
                "given name must still discriminate — John is not Ruth")
        // Without the married surname the old behaviour holds (no false match).
        let unmarked = ProjectDatabase.pendingFactHousehold(
            payload: payload, subjectName: "Ruth Brailsford")
        #expect(unmarked.first { $0.name == "Ruth Wheeldon" }?.isTarget == nil)
    }

    @Test func reacceptRetrofitsTargetOntoAStoredRosterThatHasNone() throws {
        // The stored details predate the married-surname fix: household saved
        // with NO isTarget row. A re-accept whose projection knows the
        // subject's own row marks it in place — ages/roles untouched.
        let db = try makeDB()
        try db.dbQueue.write { sql in
            try sql.execute(sql: """
                UPDATE profiles SET first_name='Ruth', last_name='Brailsford',
                    married_surname='Wheeldon' WHERE id='ernest'
                """)
        }
        let value = "1871 census, Holloway: Ruth Wheeldon (née Brailsford), 47"
        let payload: [String: Any] = [
            "event_date": "1871",
            "household": [
                ["name": "John Wheeldon", "relationship": "Head", "age": 47],
                ["name": "Ruth Wheeldon", "relationship": "Wife", "age": 47],
            ],
        ]
        let json = String(
            data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        // First accept simulating the pre-fix state: strip the target by
        // accepting under a subject the parser cannot match…
        try db.dbQueue.write { sql in
            try sql.execute(sql: "UPDATE profiles SET married_surname=NULL WHERE id='ernest'")
        }
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: json, sourceTitle: "t", sourceURL: "https://example.org/x")
        let before = try #require(try db.loadLifeEvents(profileID: "ernest")
            .first { $0.type == .census })
        guard case .census(let storedBefore)? = before.details else {
            Issue.record("expected stored census details"); return
        }
        #expect(!storedBefore.household.contains { $0.isTarget == true }, "precondition: unmarked")

        // …then the married surname lands and the same card is re-accepted.
        try db.dbQueue.write { sql in
            try sql.execute(sql: "UPDATE profiles SET married_surname='Wheeldon' WHERE id='ernest'")
        }
        try db.applyAcceptedPendingFact(
            profileID: "ernest", field: "census", value: value,
            payloadJSON: json, sourceTitle: "t", sourceURL: "https://example.org/x")
        let after = try #require(try db.loadLifeEvents(profileID: "ernest")
            .first { $0.type == .census })
        guard case .census(let storedAfter)? = after.details else {
            Issue.record("expected stored census details"); return
        }
        #expect(storedAfter.household.first { $0.name == "Ruth Wheeldon" }?.isTarget == true)
        #expect(storedAfter.household.first { $0.name == "John Wheeldon" }?.isTarget != true)
    }
}
