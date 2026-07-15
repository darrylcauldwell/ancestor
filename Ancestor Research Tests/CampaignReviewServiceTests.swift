import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// CAMPAIGN_REVIEW_SPEC Change 5 — DB-backed reconstruction of reviewable
/// results. The overnight-campaign substrate (evidence_records +
/// research_hypotheses + leads + run requests) must rebuild into the
/// ResearchResult shape the review surfaces consume, deterministically,
/// with the run's enrichment exclusion applied.
@MainActor
struct CampaignReviewServiceTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func makeProfile(id: String) -> Profile {
        Profile(
            id: id, externalIDs: [:],
            firstName: "George", lastName: "Keyworth", gender: .male,
            attributes: nil,
            birthDate: GenealogicalDate(parsing: "1877"),
            birthLocation: "Worksop, Nottinghamshire, England",
            deathDate: nil, deathLocation: nil,
            bio: nil, isDeleted: false, sources: [:], disputes: [:]
        )
    }

    private func snapshot(with profile: Profile) -> FamilyGraphSnapshot {
        FamilyGraphSnapshot(profiles: [profile.id: profile], relationships: [])
    }

    private func birthScored(id: String, year: Int, verdict: RecordVerdict = .fact) -> ScoredRecord {
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", name: "George Keyworth",
                                 surname: "Keyworth", givenName: "George",
                                 detailURL: nil, rawFields: [:]),
            birthYear: year, birthDate: String(year), birthPlace: nil,
            quarter: "Q2", district: "Worksop", volume: "7b", page: "3",
            mothersMaidenName: nil
        ))
        return ScoredRecord(id: record.id, record: record, verdict: verdict,
                            gates: [GateResult(gate: .name, outcome: .pass, reason: "ok")],
                            summary: "George Keyworth b.\(year)")
    }

    private func marriageScored(id: String) -> ScoredRecord {
        let record = SourceRecord.marriage(MarriageRecord(
            common: RecordCommon(id: id, sourceID: "freebmd", name: "Parent Marriage",
                                 surname: "Keyworth", givenName: "George",
                                 detailURL: nil, rawFields: [:]),
            marriageYear: 1860, marriageDate: nil, marriagePlace: nil,
            quarter: nil, district: "Worksop", volume: nil, page: nil, spouseName: nil
        ))
        return ScoredRecord(id: record.id, record: record, verdict: .lead,
                            gates: [], summary: "parents' marriage (enrichment)")
    }

    @Test func reconstructionSplitsVerdictsAndExcludesEnrichmentFromClusters() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "@G@")
        let snap = snapshot(with: profile)

        try db.saveEvidence(profileID: "@G@", scored: birthScored(id: "b1", year: 1877),
                            citationFull: nil, citationURL: nil, runID: "R1")
        try db.saveEvidence(profileID: "@G@", scored: birthScored(id: "b2", year: 1877, verdict: .lead),
                            citationFull: nil, citationURL: nil, runID: "R1")
        // Enrichment record (a parents'-marriage probe) — must NOT cluster.
        try db.saveEvidence(profileID: "@G@", scored: marriageScored(id: "m1"),
                            citationFull: nil, citationURL: nil,
                            isEnrichment: true, runID: "R1")

        let result = try #require(CampaignReviewService.reconstructResult(
            profileID: "@G@", db: db, snapshot: snap))

        #expect(result.confirmedFacts.map(\.id) == ["b1"])
        #expect(result.leads.map(\.id).sorted() == ["b2", "m1"])
        #expect(result.allScoredRecords.count == 3)
        #expect(result.enrichmentRecordIDs == ["m1"])
        // The enrichment marriage must not appear in any cluster.
        let clusteredIDs = Set(result.clusters.flatMap { $0.records.map(\.id) })
        #expect(!clusteredIDs.contains("m1"),
                "enrichment records must not fabricate clusters; clustered=\(clusteredIDs)")
        #expect(clusteredIDs.contains("b1"))
        // Gates survived the round trip into the reconstruction.
        #expect(result.confirmedFacts.first?.gates.first?.gate == .name)
    }

    @Test func reconstructionIsDeterministicAcrossCalls() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "@G@")
        let snap = snapshot(with: profile)
        for (i, year) in [1877, 1878, 1879].enumerated() {
            try db.saveEvidence(profileID: "@G@",
                                scored: birthScored(id: "rec\(i)", year: year),
                                citationFull: nil, citationURL: nil)
        }
        let a = try #require(CampaignReviewService.reconstructResult(profileID: "@G@", db: db, snapshot: snap))
        let b = try #require(CampaignReviewService.reconstructResult(profileID: "@G@", db: db, snapshot: snap))
        #expect(a.clusters.map(\.id) == b.clusters.map(\.id))
        #expect(a.clusters.map { $0.records.map(\.id) } == b.clusters.map { $0.records.map(\.id) })
        #expect(a.allScoredRecords.map(\.id) == b.allScoredRecords.map(\.id))
    }

    @Test func profileWithoutEvidenceReturnsNil() throws {
        let db = try makeTempDB()
        let profile = makeProfile(id: "@EMPTY@")
        #expect(CampaignReviewService.reconstructResult(
            profileID: "@EMPTY@", db: db, snapshot: snapshot(with: profile)) == nil)
    }

    @Test func campaignEntriesGroupRequestsAndCountFailures() throws {
        let db = try makeTempDB()
        let base = Date()
        // Simulate a campaign ledger directly (MCP kick_off_research shape).
        try db.dbQueue.write { conn in
            for (i, status) in ["completed", "completed", "failed"].enumerated() {
                try conn.execute(sql: """
                    INSERT INTO research_run_requests
                    (id, profile_id, mode, scope, status, error, created_at)
                    VALUES (?, ?, 'extend', 'county', ?, ?, ?)
                    """, arguments: [
                        "req_\(i)", i < 2 ? "@A@" : "@B@", status,
                        status == "failed" ? "boom" : nil,
                        base.addingTimeInterval(Double(i)),
                    ])
            }
        }
        let entries = CampaignReviewService.campaignEntries(
            since: base.addingTimeInterval(-60), db: db)
        #expect(entries.count == 2)
        let a = try #require(entries.first { $0.profileID == "@A@" })
        #expect(a.requestCount == 2 && a.completed == 2 && a.failed == 0)
        let b = try #require(entries.first { $0.profileID == "@B@" })
        #expect(b.failed == 1 && b.lastError == "boom")
        // Window respected: nothing before `since`.
        #expect(CampaignReviewService.campaignEntries(
            since: base.addingTimeInterval(120), db: db).isEmpty)
    }
}

/// CAMPAIGN_REVIEW_SPEC Change 6 — per-finding badge data.
@MainActor
struct CampaignReviewBadgeTests {

    private func makeTempDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    @Test func watermarkRoundTrips() throws {
        let db = try makeTempDB()
        // Seed the single project_meta row (real projects always have one;
        // the watermark setter is an UPDATE on it).
        try db.saveProjectMeta(Project(
            id: UUID(), name: "Test", source: .manual,
            homePersonID: nil, createdAt: Date(), lastRefreshed: nil))
        #expect(try db.campaignReviewHighWater() == nil)
        let mark = Date(timeIntervalSince1970: 1_780_000_000)
        try db.setCampaignReviewHighWater(mark)
        let loaded = try #require(try db.campaignReviewHighWater())
        #expect(abs(loaded.timeIntervalSince(mark)) < 1)
    }

    @Test func convergenceBadgeMatchesClusterFactValuesOnly() throws {
        // A cluster asserting death:1986 via a FACT record matches the
        // persisted death:1986 chain; lead-verdict assertions don't.
        let factDeath = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", name: nil,
                                 surname: "K", givenName: "G", detailURL: nil, rawFields: [:]),
            deathYear: 1986, deathDate: nil, deathPlace: nil, age: nil,
            quarter: nil, district: nil, volume: nil, page: nil, spouseSurname: nil))
        let leadDeath = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "d2", sourceID: "freebmd", name: nil,
                                 surname: "K", givenName: "G", detailURL: nil, rawFields: [:]),
            deathYear: 1992, deathDate: nil, deathPlace: nil, age: nil,
            quarter: nil, district: nil, volume: nil, page: nil, spouseSurname: nil))
        var cluster = LifeCluster(id: "cluster-0", records: [
            ScoredRecord(id: "d1", record: factDeath, verdict: .fact, gates: [], summary: ""),
            ScoredRecord(id: "d2", record: leadDeath, verdict: .lead, gates: [], summary: ""),
        ], lifespanStart: 1900, lifespanEnd: 2000)

        let sourcing = SourcingStrength(sourceCount: 3, independentLineageCount: 3,
                                        topTrustTier: .primary, independentWitnessCount: 3)
        let rows = [
            ProjectDatabase.EvidenceConvergenceRow(
                profileID: "@P@", valueKey: "death:1986", level: .confirmed,
                sourcing: sourcing, recordIDs: ["d1"], updatedAt: Date()),
            ProjectDatabase.EvidenceConvergenceRow(
                profileID: "@P@", valueKey: "death:1992", level: .probable,
                sourcing: sourcing, recordIDs: ["d2"], updatedAt: Date()),
        ]
        #expect(CampaignReviewService.convergenceLevel(for: cluster, persisted: rows) == .confirmed,
                "only FACT-verdict assertions badge; the lead's 1992 chain must not")

        // No fact records → no badge.
        cluster.records = [ScoredRecord(id: "d2", record: leadDeath, verdict: .lead, gates: [], summary: "")]
        #expect(CampaignReviewService.convergenceLevel(for: cluster, persisted: rows) == nil)
    }
}

/// CAMPAIGN_REVIEW_SPEC Change 5 — the census-split year selection is now
/// deterministic (was Dictionary.first(where:) hash order).
struct ClusteringDeterminismTests {

    private func census(id: String, year: Int, born: Int) -> ScoredRecord {
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", name: "George Keyworth",
                                 surname: "Keyworth", givenName: "George",
                                 detailURL: nil, rawFields: [:]),
            censusYear: year, age: year - born, birthYear: born, birthPlace: "Worksop",
            birthCounty: nil, relationship: nil, occupation: nil, address: nil,
            parish: nil, district: "Worksop", household: nil
        ))
        return ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: id)
    }

    @Test func duplicatedCensusYearSplitPicksLowestYear() {
        // TWO duplicated census years in one cluster — the split must pick
        // the LOWEST year every time, not hash order.
        let records = [
            census(id: "c1881a", year: 1881, born: 1877),
            census(id: "c1881b", year: 1881, born: 1877),
            census(id: "c1891a", year: 1891, born: 1877),
            census(id: "c1891b", year: 1891, born: 1877),
        ]
        var firstReasons: Set<String> = []
        for _ in 0..<10 {
            let clusters = ClusteringEngine.cluster(
                records: records, sourceInfoMap: [:], homeChapmanCode: "")
            let reasons = clusters.compactMap(\.splitReason).sorted()
            firstReasons.insert(reasons.joined(separator: " | "))
        }
        #expect(firstReasons.count == 1, "split order must be stable within a process")
        #expect(firstReasons.first?.contains("1881") == true,
                "lowest duplicated year splits first; got \(firstReasons)")
    }
}
