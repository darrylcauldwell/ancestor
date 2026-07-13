import Testing
import Foundation
import GRDB
@testable import Ancestor_Research

/// CONFLICT_LAYER_SPEC §4.3 — C3, the DisputeStore: idempotent upsert
/// keyed on (entity_id, kind, field), competing-source join, witness-gated
/// reopen scaffolding ⟨G3⟩ (value-novelty surrogate until CL4), the
/// `detected_by` stamp ⟨G6⟩, and the surfacing queries.
struct DisputeStoreTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func seedProfile(_ db: ProjectDatabase, id: String = "p1") throws {
        let profile = Profile(
            id: id, externalIDs: [:],
            firstName: "William", lastName: "Cauldwell",
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: GenealogicalDate(parsing: "1901"), deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
        _ = try db.addProfile(profile, source: .gedcom)
    }

    private func deathConflict(
        candidateRaw: String = "Dec 1900",
        candidateOrigin: SourceOrigin = .freebmd,
        severity: DiscrepancySeverity = .note
    ) -> DetectedConflict {
        DetectedConflict(
            kind: .fieldValue,
            profileID: "p1",
            field: "deathDate",
            reason: .noOverlap,
            severity: severity,
            competingSources: [
                FieldSource(origin: .gedcom, raw: "1901", addedAt: Date(timeIntervalSince1970: 0)),
                FieldSource(origin: candidateOrigin, raw: candidateRaw, addedAt: Date(timeIntervalSince1970: 0)),
            ],
            evidenceJSON: nil,
            reasoning: "test conflict",
            detectedBy: .applyEngine
        )
    }

    private func adjudicated(_ conflict: DetectedConflict) -> DisputeResolver.Adjudication {
        DisputeResolver.adjudicate(conflict)
    }

    // MARK: - Insert stamps everything

    @Test func upsertInsertsOpenRowWithProducerSeverityTraceAndSummary() throws {
        let db = try makeDB()
        try seedProfile(db)
        let conflict = deathConflict()
        let rowid = try db.upsertDispute(
            profileID: "p1", conflict: conflict, adjudication: adjudicated(conflict)
        )
        #expect(rowid > 0)

        let rows = try db.openDisputes(profileID: "p1")
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.kind == .fieldValue)
        #expect(row.field == "deathDate")
        #expect(row.reason == .noOverlap)
        #expect(row.detectedBy == .applyEngine)   // ⟨G6⟩
        #expect(row.severity == .note)
        #expect(row.resolution == nil)
        #expect(row.resolvedAt == nil)
        #expect(row.competingSources.count == 2)
        // ⟨G2⟩ ladder trace persisted with every rung.
        let trace = try JSONDecoder().decode(
            [DisputeResolver.RungEvaluation].self,
            from: Data((row.ladderTrace ?? "[]").utf8)
        )
        #expect(trace.map(\.rung) == ["R3", "R0", "R1", "R2"])
        // ⟨G8⟩ interim witness summary present.
        #expect(row.witnessSummary?.contains("1901") == true)
        #expect(row.witnessSummary?.contains("Dec 1900") == true)
    }

    // MARK: - Idempotence (AC1's re-apply clause)

    @Test func identicalRedetectionIsANoOp() throws {
        let db = try makeDB()
        try seedProfile(db)
        let conflict = deathConflict()
        let first = try db.upsertDispute(profileID: "p1", conflict: conflict, adjudication: adjudicated(conflict))
        let second = try db.upsertDispute(profileID: "p1", conflict: conflict, adjudication: adjudicated(conflict))
        #expect(first == second)
        #expect(try db.openDisputes(profileID: "p1").count == 1)
        #expect(try db.openDisputeCount() == 1)
    }

    @Test func newCompetingValueJoinsTheOpenDispute() throws {
        let db = try makeDB()
        try seedProfile(db)
        let conflict = deathConflict()
        let rowid = try db.upsertDispute(profileID: "p1", conflict: conflict, adjudication: adjudicated(conflict))

        // A third value arrives (another quarter from FamilySearch).
        let joiner = deathConflict(candidateRaw: "Mar 1899", candidateOrigin: .familysearch, severity: .conflict)
        let joined = try db.upsertDispute(profileID: "p1", conflict: joiner, adjudication: adjudicated(joiner))
        #expect(joined == rowid)

        let rows = try db.openDisputes(profileID: "p1")
        #expect(rows.count == 1)
        #expect(rows[0].competingSources.contains { $0.raw == "Mar 1899" })
        #expect(rows[0].competingSources.count == 3)
        // Severity floor-ratchets upward, never down.
        #expect(rows[0].severity == .conflict)
        // Witness summary recomputed over the merged set.
        #expect(rows[0].witnessSummary?.contains("Mar 1899") == true)
    }

    @Test func severityNeverDowngradesOnJoin() throws {
        let db = try makeDB()
        try seedProfile(db)
        let severe = deathConflict(severity: .correction)
        _ = try db.upsertDispute(profileID: "p1", conflict: severe, adjudication: adjudicated(severe))
        let mild = deathConflict(candidateRaw: "Jun 1899", severity: .note)
        _ = try db.upsertDispute(profileID: "p1", conflict: mild, adjudication: adjudicated(mild))
        #expect(try db.openDisputes(profileID: "p1")[0].severity == .correction)
    }

    @Test func distinctKindsForOneFieldCoexist() throws {
        let db = try makeDB()
        try seedProfile(db)
        let fieldValue = deathConflict()
        _ = try db.upsertDispute(profileID: "p1", conflict: fieldValue, adjudication: adjudicated(fieldValue))
        let timeline = DetectedConflict(
            kind: .timeline, profileID: "p1", field: "deathDate",
            reason: .valueMismatch, severity: .conflict,
            competingSources: [FieldSource(origin: .freecen, raw: "census 1911", addedAt: Date())],
            evidenceJSON: nil, reasoning: "death 1905 vs census 1911",
            detectedBy: .consistencySweep
        )
        _ = try db.upsertDispute(profileID: "p1", conflict: timeline, adjudication: adjudicated(timeline))
        let rows = try db.openDisputes(profileID: "p1")
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.kind)) == [.fieldValue, .timeline])
    }

    // MARK: - Witness-gated reopen scaffolding ⟨G3⟩

    @Test func alreadyWeighedValueDoesNotReopenAResolvedDispute() throws {
        let db = try makeDB()
        try seedProfile(db)
        let conflict = deathConflict()
        _ = try db.upsertDispute(profileID: "p1", conflict: conflict, adjudication: adjudicated(conflict))
        _ = try db.resolveFieldDispute(
            profileID: "p1", field: .deathDate,
            resolution: .accepted(conflict.competingSources[0])
        )
        #expect(try db.openDisputes(profileID: "p1").isEmpty)

        // The same values re-detected (another apply of the same record):
        // every asserted value was already weighed — never re-litigate.
        let redetected = deathConflict()
        _ = try db.upsertDispute(profileID: "p1", conflict: redetected, adjudication: adjudicated(redetected))
        #expect(try db.openDisputes(profileID: "p1").isEmpty)
        #expect(try db.allDisputes(profileID: "p1").count == 1)
    }

    @Test func genuinelyNewValueReopensAsANewRow() throws {
        let db = try makeDB()
        try seedProfile(db)
        let conflict = deathConflict()
        _ = try db.upsertDispute(profileID: "p1", conflict: conflict, adjudication: adjudicated(conflict))
        _ = try db.resolveFieldDispute(
            profileID: "p1", field: .deathDate,
            resolution: .accepted(conflict.competingSources[0])
        )

        // A value nobody weighed at resolution time (1899) arrives.
        let novel = deathConflict(candidateRaw: "1899")
        _ = try db.upsertDispute(profileID: "p1", conflict: novel, adjudication: adjudicated(novel))

        let open = try db.openDisputes(profileID: "p1")
        #expect(open.count == 1)
        #expect(open[0].competingSources.contains { $0.raw == "1899" })
        // The resolved row is history — preserved, not mutated (§3).
        let all = try db.allDisputes(profileID: "p1")
        #expect(all.count == 2)
        #expect(all.contains { $0.resolution != nil })
    }

    // MARK: - Surfacing queries

    @Test func surfacingQueriesCoverOpenCountsAndDossierContract() throws {
        let db = try makeDB()
        try seedProfile(db)
        try seedProfile(db, id: "p2")
        let c1 = deathConflict()
        _ = try db.upsertDispute(profileID: "p1", conflict: c1, adjudication: adjudicated(c1))
        let c2 = DetectedConflict(
            kind: .spouseIdentity, profileID: "p2", field: "spouse",
            reason: .valueMismatch, severity: .conflict,
            competingSources: [FieldSource(origin: .freebmd, raw: "marriage names SMITH", addedAt: Date())],
            evidenceJSON: "{\"recordIDs\":[\"m1\"]}",
            reasoning: "F4b", detectedBy: .applyEngine
        )
        _ = try db.upsertDispute(profileID: "p2", conflict: c2, adjudication: adjudicated(c2))

        #expect(try db.openDisputeCount() == 2)
        #expect(try db.allOpenDisputes().count == 2)
        #expect(try db.openDisputes(profileID: "p1").count == 1)
        #expect(try db.openDisputes(profileID: "p2").count == 1)
        // allDisputes is the T9 dossier contract: open + resolved with
        // trace/summary carried verbatim.
        let dossier = try db.allDisputes(profileID: "p2")
        #expect(dossier.count == 1)
        #expect(dossier[0].kind == .spouseIdentity)
        #expect(dossier[0].evidenceJSON?.contains("m1") == true)
        #expect(dossier[0].ladderTrace != nil)
    }

    // MARK: - Undo cascade (transaction-bound dispute rows)

    @Test func disputeBoundToTransactionCascadesOnStructuralUndo() throws {
        let db = try makeDB()
        try seedProfile(db)
        // Mirror the apply path: alternative-fact transaction, dispute
        // bound to it.
        let tx = try db.recordAlternativeFact(
            profileID: "p1", field: .deathDate, rawValue: "Dec 1900", source: .freebmd
        )
        let conflict = deathConflict()
        _ = try db.upsertDispute(
            profileID: "p1", conflict: conflict,
            adjudication: adjudicated(conflict), transactionID: tx.id
        )
        #expect(try db.openDisputeCount() == 1)

        try db.undoStructural(transactionID: tx.id)
        #expect(try db.openDisputeCount() == 0)
    }
}
