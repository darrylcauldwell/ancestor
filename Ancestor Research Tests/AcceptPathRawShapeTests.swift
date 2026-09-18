import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// EV9 (2026-08-26) — `field_sources.raw` carries TWO shapes, and the readers
/// that write a profile column from it only understood one.
///
/// The pending-facts accept path stores `"<value> [<sourceTitle>]"`
/// (`ProjectDatabase+PendingFactsReview.addAcceptedFactProvenance`) while the
/// profile COLUMN gets the bare value. Every other writer stores the value
/// alone. `AppliedFactTarget.parseRaw` has always existed to decode both, and
/// the un-apply and sources-ledger paths already use it.
///
/// These tests pin the three readers that treat `raw` as a VALUE:
///  * the consistency sweep, which disputed "Chesterfield" against
///    "Chesterfield [FreeBMD Birth Index]" — one value, opened against itself,
///    never retracted (`ConflictSweep` never withdraws a `fieldValue` dispute);
///  * dispute resolution, which wrote the bracketed string straight into
///    `birth_location` when the user picked that competitor;
///  * the birth/death-year candidate apply, which wrote it into
///    `birth_date_original` and then minted a FRESH provenance row carrying the
///    composite under an apply-path origin.
///
/// The WRITE format is deliberately untouched: the bracket is the sources-
/// ledger entry label and the MCP §14.3 auto-approval convergence gate's
/// independent-lineage proxy, and `raw` is a match key in five places. Fixing
/// this read-side rewrites no stored row.
@MainActor
struct AcceptPathRawShapeTests {

    // MARK: - Scaffolding (proven shape, from AppliedFactRemovalTests)

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        // ConflictSweep reads its high-water column off this row.
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        _ = try db.addProfile(
            Profile(id: "p", firstName: "John", lastName: "Cauldwell", gender: .male,
                    birthDate: GenealogicalDate(parsing: "BET 1869 AND 1896"),
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .manual)
        return db
    }

    /// The REAL accept path — this is what produces the composite raw.
    private func accept(
        _ db: ProjectDatabase, field: String, value: String,
        title: String, origin: String
    ) throws {
        try db.applyAcceptedPendingFact(profileID: "p", field: field, value: value)
        try db.addAcceptedFactProvenance(
            profileID: "p", field: field, value: value,
            sourceTitle: title, sourceURL: nil, origin: origin)
    }

    private func column(_ db: ProjectDatabase, _ sql: String) throws -> String? {
        try db.dbQueue.read { d in
            try String.fetchOne(d, sql: "SELECT \(sql) FROM profiles WHERE id = 'p'")
        }
    }

    // MARK: - The consistency sweep

    /// The live symptom: every accepted location opened a `fieldValue` dispute
    /// against itself, because the column holds "Chesterfield" and the only
    /// attested row is the same value with its source title appended.
    @Test func acceptedBirthplaceDoesNotDisputeItself() throws {
        let db = try makeDB()
        try accept(db, field: "birthLocation", value: "Chesterfield",
                   title: "FreeBMD Birth Index", origin: "research-run")

        _ = try ConflictSweep.run(db: db, snapshot: try db.buildSnapshot(), force: true)

        let open = try db.openDisputes(profileID: "p").filter { $0.field == "birthLocation" }
        #expect(open.isEmpty,
                "the column holds 'Chesterfield' and the only attested row is the same value with its source title appended — that is one value, not two")
    }

    /// Falsification guard: a GENUINE disagreement must still open a dispute.
    /// Passes before and after the fix; if it ever stops passing, the fix has
    /// stopped detecting real conflicts rather than self-comparisons.
    @Test func aGenuineLocationDisagreementStillOpensADispute() throws {
        let db = try makeDB()
        try accept(db, field: "birthLocation", value: "Chesterfield",
                   title: "FreeBMD Birth Index", origin: "research-run")
        try db.dbQueue.write {
            try $0.execute(sql: "UPDATE profiles SET birth_location = 'Belper' WHERE id = 'p'")
        }

        _ = try ConflictSweep.run(db: db, snapshot: try db.buildSnapshot(), force: true)

        #expect(try db.openDisputes(profileID: "p").contains { $0.field == "birthLocation" })
    }

    // MARK: - Dispute resolution

    /// Picking the bracketed competitor in the Resolve sheet wrote
    /// "Chesterfield [FreeBMD Birth Index]" into `birth_location`.
    @Test func resolvingADisputeWritesTheValueNotTheBracketedTitle() throws {
        let db = try makeDB()
        try db.dbQueue.write {
            try $0.execute(sql: "UPDATE profiles SET birth_location = 'Belper' WHERE id = 'p'")
        }
        let origin = SourceOrigin(identifier: "research-run")
        let conflict = try #require(ConflictDetector.stringFieldConflict(
            field: .birthLocation, existing: "Belper", existingSources: [],
            candidate: "Chesterfield", candidateOrigin: origin, profileID: "p"))
        // An OPEN field_disputes row is mandatory — `resolveFieldDispute` bails
        // out of the whole write when it finds none.
        _ = try db.upsertDispute(profileID: "p", conflict: conflict,
                                 adjudication: DisputeResolver.adjudicate(conflict))

        let picked = FieldSource(
            origin: origin, raw: "Chesterfield [FreeBMD Birth Index]", addedAt: Date())
        _ = try db.resolveFieldDispute(
            profileID: "p", field: .birthLocation, resolution: .accepted(picked))

        #expect(try column(db, "birth_location") == "Chesterfield")
    }

    // MARK: - The year-candidate apply

    /// `applyBirthYearCandidate` prefers an attested source's `raw` for its
    /// month detail. When that source came from the accept path the bracketed
    /// title rode along into `birth_date_original` — and the apply then minted
    /// a fresh provenance row carrying it under an apply-path origin, so the
    /// composite escaped the accept-path namespace entirely.
    @Test func birthYearCandidateApplyWritesTheBareDate() throws {
        let db = try makeDB()   // profile birthDate = "BET 1869 AND 1896"
        try db.addAcceptedFactProvenance(
            profileID: "p", field: "birthDate", value: "Dec 1883",
            sourceTitle: "FreeBMD Births", sourceURL: nil, origin: "research-run")
        _ = try db.recordAlternativeFact(
            profileID: "p", field: .birthDate, rawValue: "Jun 1870", source: .freebmd)

        let kind = HypothesisKind.birthYearCandidate(profileID: "p", year: 1883)
        let now = Date()
        let hypothesis = ResearchHypothesis(
            id: kind.identityKey(subjectProfileID: "p"), subjectProfileID: "p",
            kind: kind, verdict: .supported, isModelAssisted: false,
            supportingEvidence: [], contradictingEvidence: [], reasoning: "fixture",
            createdAt: now, lastTestedAt: now, attempts: 1, history: [])

        try ApplyEngine.applyBirthYearCandidate(
            hypothesis, snapshot: try db.buildSnapshot(), db: db)

        #expect(try column(db, "birth_date_original") == "Dec 1883")
    }
}
