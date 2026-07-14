import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// CONFLICT_LAYER_SPEC CL2 — the standing sweep (T-C), acceptance criteria
/// 1–5, plus the shared-predicate lock (AC2: sweep and audit rule can
/// never disagree) and the ClusteringEngine T-D split (AC3).
struct ConflictSweepTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        // Production DBs always carry the single project_meta row
        // (ProjectStore seeds it at creation); the sweep's high-water and
        // backfill flags are columns on it. Mirror reality here.
        try db.dbQueue.write { sql in
            try sql.execute(sql: """
                INSERT INTO project_meta (id, name, source_kind, source_value, created_at)
                VALUES ('test', 'Test Project', 'manual', '', ?)
                """, arguments: [Date()])
        }
        return db
    }

    private func profile(
        _ id: String, firstName: String = "John", lastName: String = "Smith",
        deathDate: GenealogicalDate? = nil
    ) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: firstName, lastName: lastName,
            gender: .male, attributes: nil,
            birthDate: nil, birthLocation: nil,
            deathDate: deathDate, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func censusEvent(_ profileID: String, year: Int, location: String? = nil) -> LifeEvent {
        LifeEvent(
            id: UUID(), profileID: profileID, type: .census,
            date: GenealogicalDate(parsing: String(year)), location: location
        )
    }

    // MARK: - AC1: DS-15 retroactive death-vs-later-alive, order-independent

    @Test func deathContradictedByLaterCensusOpensTimelineDispute() throws {
        let db = try makeDB()
        let p = profile("p1", deathDate: GenealogicalDate(parsing: "1905"))
        _ = try db.addProfile(p, source: .gedcom)
        // Alive-evidence written AFTER the death was already known — the
        // exact write order the apply-time hook cannot catch (DS-15).
        _ = try db.addLifeEvent(censusEvent("p1", year: 1911, location: "Belper"))

        let snapshot = try db.buildSnapshot()
        let report = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)

        #expect(report.disputesTouched >= 1)
        let open = try db.openDisputes(profileID: "p1")
        let timeline = open.first { $0.kind == .timeline && $0.field == "death-vs-alive" }
        #expect(timeline != nil)
        #expect(timeline?.detectedBy == .consistencySweep)
    }

    // MARK: - AC2: two mothers flagged by sweep AND audit rule (shared predicate)

    @Test func twoBiologicalMothersFlaggedBySweepAndAuditRuleAlike() throws {
        let db = try makeDB()
        _ = try db.addProfile(profile("child"), source: .gedcom)
        _ = try db.addProfile(profile("m1", firstName: "Mary", lastName: "Bown"), source: .gedcom)
        _ = try db.addProfile(profile("m2", firstName: "Sarah", lastName: "Land"), source: .gedcom)
        for mother in ["m1", "m2"] {
            _ = try db.addRelationship(Relationship(
                id: UUID(), from: mother, to: "child", type: .parent,
                role: .mother, subtype: .biological,
                marriageDate: nil, marriageLocation: nil, divorceDate: nil
            ))
        }

        let snapshot = try db.buildSnapshot()

        // The sweep opens a parentRole dispute…
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        let open = try db.openDisputes(profileID: "child")
        #expect(open.contains { $0.kind == .parentRole && $0.field == "mother" })

        // …and the audit rule fires from the SAME predicate.
        guard let child = snapshot.profiles["child"] else {
            Issue.record("child profile missing from snapshot")
            return
        }
        let results = ParentsPerRoleRule().evaluate(profile: child, snapshot: snapshot)
        #expect(results.count == 1)
        #expect(results.first?.ruleID == "parentsPerRole")

        // Shared-predicate lock: both fire or neither — assert directly on
        // the predicate both consume.
        let duplicates = ConflictPredicates.duplicateBiologicalParentEdges(
            subjectID: "child", relationships: snapshot.relationships)
        #expect(duplicates[.mother]?.count == 2)
    }

    // MARK: - AC3: same-enumeration-year duplicates (tree state)

    @Test func twoSameYearCensusEventsOpenTimelineDispute() throws {
        let db = try makeDB()
        _ = try db.addProfile(profile("p1"), source: .gedcom)
        _ = try db.addLifeEvent(censusEvent("p1", year: 1881, location: "Belper"))
        _ = try db.addLifeEvent(censusEvent("p1", year: 1881, location: "Duffield"))

        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)

        let open = try db.openDisputes(profileID: "p1")
        #expect(open.contains { $0.kind == .timeline && $0.field == "census-1881" })
    }

    // MARK: - AC4: idempotency + high-water skip

    @Test func secondSweepRunAddsZeroRows() throws {
        let db = try makeDB()
        let p = profile("p1", deathDate: GenealogicalDate(parsing: "1905"))
        _ = try db.addProfile(p, source: .gedcom)
        _ = try db.addLifeEvent(censusEvent("p1", year: 1911))

        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        let countAfterFirst = try db.openDisputeCount()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        let countAfterSecond = try db.openDisputeCount()
        #expect(countAfterFirst == countAfterSecond)
    }

    @Test func highWaterMarkSkipsUnchangedProject() throws {
        let db = try makeDB()
        _ = try db.addProfile(profile("p1"), source: .gedcom)
        let snapshot = try db.buildSnapshot()

        let first = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        #expect(!first.skippedUnchanged)

        // Unforced re-run on an unchanged project skips.
        let second = try ConflictSweep.run(db: db, snapshot: snapshot)
        #expect(second.skippedUnchanged)
        #expect(second.profilesScanned == 0)

        // force always runs.
        let third = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)
        #expect(!third.skippedUnchanged)
    }

    // MARK: - AC5: one-shot backfill

    @Test func backfillRunsExactlyOnce() throws {
        let db = try makeDB()
        let p = profile("p1", deathDate: GenealogicalDate(parsing: "1905"))
        _ = try db.addProfile(p, source: .gedcom)
        _ = try db.addLifeEvent(censusEvent("p1", year: 1911))
        let snapshot = try db.buildSnapshot()

        let first = try ConflictSweep.backfillIfNeeded(db: db, snapshot: snapshot)
        #expect(first != nil)
        #expect((first?.disputesTouched ?? 0) >= 1)

        let second = try ConflictSweep.backfillIfNeeded(db: db, snapshot: snapshot)
        #expect(second == nil)
    }

    // MARK: - F1 retroactive: attested value disjoint from canonical

    @Test func sweepSurfacesAttestedDateDisjointFromCanonical() throws {
        let db = try makeDB()
        let p = profile("p1", deathDate: GenealogicalDate(parsing: "1901"))
        // Canonical provenance is freebmd — SAME CLASS as the disjoint
        // freebmd attestation below — so CL5's R2 ladder can't rank them
        // and the sweep surfaces an OPEN dispute (two GRO transcriptions of
        // different quarters). A cross-class pair would DS-09-resolve.
        _ = try db.addProfile(p, source: .freebmd)
        // A second, disjoint attestation recorded as an alternative fact —
        // the first-writer-wins residue the sweep must surface (DS-08).
        try db.dbQueue.write { sql in
            try sql.execute(sql: """
                INSERT INTO field_sources (entity_id, entity_kind, field, origin, raw, added_at)
                VALUES ('p1', 'profile', 'deathDate', 'freebmd', '1907', ?)
                """, arguments: [Date()])
        }

        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)

        let open = try db.openDisputes(profileID: "p1")
        #expect(open.contains { $0.kind == .fieldValue && $0.field == "deathDate" })
    }

    // MARK: - burial/probate symmetric arm

    @Test func burialEventContradictedByLaterCensus() throws {
        let db = try makeDB()
        _ = try db.addProfile(profile("p1"), source: .gedcom)  // no deathDate
        _ = try db.addLifeEvent(LifeEvent(
            id: UUID(), profileID: "p1", type: .burial,
            date: GenealogicalDate(parsing: "1890")))
        _ = try db.addLifeEvent(censusEvent("p1", year: 1901))

        let snapshot = try db.buildSnapshot()
        _ = try ConflictSweep.run(db: db, snapshot: snapshot, force: true)

        let open = try db.openDisputes(profileID: "p1")
        #expect(open.contains { $0.kind == .timeline && $0.field == "death-vs-alive" })
    }
}

/// CL2 AC3 (cluster arm) — T-D ⟨G13⟩: same-enumeration-year records force
/// a cluster split.
struct ClusteringSameYearSplitTests {

    @Test func sameCensusYearRecordsForceSplit() {
        let common1 = RecordCommon(
            id: "c1", sourceID: "freecen", name: "John Smith",
            surname: "Smith", givenName: "John", detailURL: nil, rawFields: [:])
        let common2 = RecordCommon(
            id: "c2", sourceID: "familysearch", name: "John Smith",
            surname: "Smith", givenName: "John", detailURL: nil, rawFields: [:])
        let r1 = SourceRecord.census(CensusRecord(common: common1, censusYear: 1881, birthYear: 1848))
        let r2 = SourceRecord.census(CensusRecord(common: common2, censusYear: 1881, birthYear: 1852))

        let scored = [r1, r2].map { record in
            ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
        }
        let clusters = ClusteringEngine.cluster(
            records: scored, sourceInfoMap: [:], homeChapmanCode: "")

        // The two same-year census records must not share a cluster.
        for cluster in clusters {
            let years = cluster.records.compactMap { record -> Int? in
                if case .census(let r) = record.record { return r.censusYear }
                return nil
            }
            #expect(years.count <= 1, "same-census-year records fused in one cluster")
        }
    }
}
