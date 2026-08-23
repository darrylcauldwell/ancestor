import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// The per-record kin roster: each relative a parish record names is
/// assessed against the tree — in tree (spelling variants counted), differs
/// from the tree's holder of that role, or not in tree and addable.
///
/// Owner dogfood 2026-08-23. Details on Mary Stevenson's applied baptism
/// surfaced "Father John STEPHENSON · Mother Lydia" — and stopped there:
/// "no option to see if these are already persons in tree, if there is
/// discrepancy between record and profiles in tree and … no method to add
/// these profiles." The existing net-new filter also silently DROPPED the
/// discrepancy case (a different father in the role just vanished).
@MainActor
struct ParishKinAssessmentTests {

    private func makeAppState(snapshot: FamilyGraphSnapshot) throws -> AppState {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        let appState = AppState()
        appState.currentDatabase = db
        appState.snapshot = snapshot
        return appState
    }

    private func profile(_ id: String, _ given: String, last: String?,
                         gender: Gender?) -> Profile {
        Profile(id: id, externalIDs: [:], firstName: given, middleName: nil,
                lastName: last, gender: gender, attributes: nil,
                birthDate: nil, birthLocation: nil, deathDate: nil,
                deathLocation: nil, bio: nil, isDeleted: false,
                sources: [:], disputes: [:])
    }

    private func parentEdge(parent: String, child: String, role: ParentRole) -> Relationship {
        Relationship(id: UUID(), from: parent, to: child, type: .parent,
                     role: role, subtype: .biological,
                     marriageDate: nil, marriageLocation: nil, divorceDate: nil)
    }

    /// Mary's baptism exactly as the Details fetch stores it: flat parents,
    /// no typed detail needed (the synthesis path covers it).
    private func baptismEvidence(profileID: String,
                                 father: String? = "John STEPHENSON",
                                 mother: String? = "Lydia") -> EvidenceRecord {
        let record = ParishRecord(
            common: RecordCommon(id: "bapt-mary", sourceID: "freereg",
                                 name: "Mary STEPHENSON", surname: "STEPHENSON",
                                 givenName: "Mary",
                                 detailURL: "https://freereg/mary", rawFields: [:]),
            eventType: "baptism", eventDate: "28 Dec 1823", eventYear: 1823,
            parish: "Youlgreave", county: "Derbyshire",
            fatherName: father, motherName: mother, detail: nil)
        return EvidenceRecord(
            id: EvidenceRecord.compositeID(profileID: profileID, sourceRecordID: "bapt-mary"),
            profileID: profileID, sourceID: "freereg", sourceRecordID: "bapt-mary",
            recordType: .parish, verdict: .lead, record: .parish(record),
            citationFull: "FreeREG, Youlgreave, 1823",
            citationURL: "https://freereg/mary",
            scoredAt: Date(), userStatus: .savedAsLead)
    }

    // MARK: - Not in tree → addable

    @Test func parentsAbsentFromTheTreeAreAddable() throws {
        let mary = profile("mary", "Mary", last: "Stevenson", gender: .female)
        let app = try makeAppState(snapshot: FamilyGraphSnapshot(
            profiles: [mary.id: mary], relationships: []))
        let kin = app.parishKinAssessments(for: mary, evidence: [baptismEvidence(profileID: mary.id)])
        let rec = try #require(kin["bapt-mary"])
        #expect(rec.assessments.count == 2)
        #expect(rec.assessments.allSatisfy { $0.match == .notOnTree })
        #expect(rec.addable.count == 2)
        #expect(rec.eventYear == 1823)
    }

    // MARK: - Already in tree, variant spelling → match, never a discrepancy

    @Test func variantSpelledFatherOnTreeMatches() throws {
        // Tree father John STEVENSON; record says STEPHENSON — one clerk,
        // not a conflict (the exact pair that hid Mary's baptism).
        let mary = profile("mary", "Mary", last: "Stevenson", gender: .female)
        let john = profile("john", "John", last: "Stevenson", gender: .male)
        let app = try makeAppState(snapshot: FamilyGraphSnapshot(
            profiles: [mary.id: mary, john.id: john],
            relationships: [parentEdge(parent: john.id, child: mary.id, role: .father)]))
        let rec = try #require(app.parishKinAssessments(
            for: mary, evidence: [baptismEvidence(profileID: mary.id)])["bapt-mary"])
        let father = try #require(rec.assessments.first { $0.roleLabel == "Father" })
        #expect(father.match == .onTree(existingName: "John Stevenson"))
        // Mother Lydia is still missing — only she is addable.
        #expect(rec.addable.map(\.gender) == [.female])
    }

    @Test func givenNameContainmentMatchesTheTreesFullerName() throws {
        // Record "Lydia"; tree mother "Lydia Ann" — same person, fuller name.
        let mary = profile("mary", "Mary", last: "Stevenson", gender: .female)
        let lydia = profile("lydia", "Lydia Ann", last: nil, gender: .female)
        let app = try makeAppState(snapshot: FamilyGraphSnapshot(
            profiles: [mary.id: mary, lydia.id: lydia],
            relationships: [parentEdge(parent: lydia.id, child: mary.id, role: .mother)]))
        let rec = try #require(app.parishKinAssessments(
            for: mary, evidence: [baptismEvidence(profileID: mary.id)])["bapt-mary"])
        let mother = try #require(rec.assessments.first { $0.roleLabel == "Mother" })
        #expect(mother.match == .onTree(existingName: "Lydia Ann"))
    }

    // MARK: - Role filled by a DIFFERENT name → surfaced, never addable

    @Test func differentFatherInRoleIsADiscrepancyNotAnAdd() throws {
        let mary = profile("mary", "Mary", last: "Stevenson", gender: .female)
        let wrong = profile("w", "William", last: "Holmes", gender: .male)
        let app = try makeAppState(snapshot: FamilyGraphSnapshot(
            profiles: [mary.id: mary, wrong.id: wrong],
            relationships: [parentEdge(parent: wrong.id, child: mary.id, role: .father)]))
        let rec = try #require(app.parishKinAssessments(
            for: mary, evidence: [baptismEvidence(profileID: mary.id)])["bapt-mary"])
        let father = try #require(rec.assessments.first { $0.roleLabel == "Father" })
        #expect(father.match == .differsFromTree(existingName: "William Holmes"))
        // A second father is never addable; the missing mother still is.
        #expect(rec.addable.map(\.gender) == [.female])
    }

    // MARK: - The direct matcher

    @Test func learnedEquivalencePairsCountAsMatches() {
        // STINSON↔STEPHENSON: reached by no generated rule and no curated
        // seed (STEENSON, the first fixture tried here, turned out to be
        // curated already) — only the tree's own learned pair can bridge it.
        let p = profile("x", "John", last: "Stinson", gender: .male)
        let link = AppState.ParishFamilyLink(
            relation: .parent, given: "John", birthSurname: "STEPHENSON",
            marriedSurname: nil, gender: .male)
        #expect(!AppState.parishKinNameMatches(p, link: link))
        #expect(AppState.parishKinNameMatches(
            p, link: link, learned: [("STINSON", "STEPHENSON")]))
    }

    @Test func surnamelessMotherMatchesOnGivenNameAlone() {
        let p = profile("x", "Lydia", last: nil, gender: .female)
        let link = AppState.ParishFamilyLink(
            relation: .parent, given: "Lydia", birthSurname: nil,
            marriedSurname: "Stevenson", gender: .female)
        #expect(AppState.parishKinNameMatches(p, link: link))
    }

    // MARK: - Card-open backfill selection (auto Details, applied-only)

    private func evidence(_ id: String, record: SourceRecord,
                          status: UserReviewStatus) -> EvidenceRecord {
        EvidenceRecord(
            id: EvidenceRecord.compositeID(profileID: "p", sourceRecordID: id),
            profileID: "p", sourceID: "freereg", sourceRecordID: id,
            recordType: .parish, verdict: .lead, record: record,
            citationFull: nil, citationURL: nil,
            scoredAt: Date(), userStatus: status)
    }

    private func bareParish(_ id: String) -> SourceRecord {
        .parish(ParishRecord(
            common: RecordCommon(id: id, sourceID: "freereg", name: "Mary STEPHENSON",
                                 detailURL: "https://freereg/\(id)", rawFields: [:]),
            eventType: "baptism", eventYear: 1823, detail: nil))
    }

    @Test func backfillSelectsOnlyKeptRecordsStillMissingDetail() {
        let kept = evidence("kept", record: bareParish("kept"), status: .savedAsLead)
        let candidate = evidence("cand", record: bareParish("cand"), status: .unreviewed)
        let rejected = evidence("rej", record: bareParish("rej"), status: .discarded)
        let picked = AppState.appliedEvidenceNeedingDetail(
            [candidate, kept, rejected], profile: nil, attempted: [])
        #expect(picked.map(\.sourceRecordID) == ["kept"],
                "candidates stay behind the explicit Details click; discarded rows are never fetched")
    }

    @Test func backfillSkipsAttemptedAndHonoursTheCap() {
        let rows = (0..<6).map { evidence("r\($0)", record: bareParish("r\($0)"), status: .savedAsLead) }
        let picked = AppState.appliedEvidenceNeedingDetail(
            rows, profile: nil, attempted: [rows[0].id], cap: 3)
        #expect(picked.map(\.sourceRecordID) == ["r1", "r2", "r3"],
                "a failed fetch is not retried this session, and one card open is a bounded number of GETs")
    }

    @Test func backfillIgnoresRecordsAlreadyCarryingDetail() {
        let full = ParishRecord(
            common: RecordCommon(id: "full", sourceID: "freereg", name: "Mary STEPHENSON",
                                 detailURL: "https://freereg/full", rawFields: [:]),
            eventType: "baptism",
            detail: FreeREGDetail(event: .baptism(FreeREGBaptism(
                child: FreeREGPerson(forename: "Mary", surname: "STEPHENSON")))))
        let done = evidence("full", record: .parish(full), status: .savedAsLead)
        #expect(AppState.appliedEvidenceNeedingDetail([done], profile: nil, attempted: []).isEmpty)
    }
}
