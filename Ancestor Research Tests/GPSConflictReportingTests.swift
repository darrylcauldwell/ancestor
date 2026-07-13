import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// CONFLICT_LAYER_SPEC CL3 — honest reporting: GPS criterion 4 can fire
/// (AC1/AC2), criterion 3 scores per asserted value (AC3), run
/// discrepancies persist with run linkage and open disputes (AC4), and
/// the bulk-review .conflict friction tier is reachable (AC5).
struct GPSConflictReportingTests {

    // MARK: - Fixtures

    private func birthRecord(_ id: String, year: Int, source: String = "freebmd") -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: source, name: "John Smith",
            surname: "Smith", givenName: "John", detailURL: nil, rawFields: [:])
        return ScoredRecord(
            id: id, record: .birth(BirthRecord(common: common, birthYear: year)),
            verdict: .fact, gates: [], summary: "birth \(year)")
    }

    private func censusRecord(_ id: String, impliedBirth: Int, source: String = "freecen") -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: source, name: "John Smith",
            surname: "Smith", givenName: "John", detailURL: nil, rawFields: [:])
        return ScoredRecord(
            id: id, record: .census(CensusRecord(common: common, censusYear: 1901, birthYear: impliedBirth)),
            verdict: .fact, gates: [], summary: "census implies \(impliedBirth)")
    }

    private func result(
        facts: [ScoredRecord] = [],
        clusters: [LifeCluster] = [],
        discrepancies: [ResearchDiscrepancy] = []
    ) -> ResearchResult {
        ResearchResult(
            confirmedFacts: facts, leads: [], allScoredRecords: facts,
            clusters: clusters, discrepancies: discrepancies,
            householdMembers: [], searchHistory: [])
    }

    private func disputeRow(
        field: String = "deathDate",
        resolution: DisputeResolution? = nil
    ) -> DisputeRow {
        DisputeRow(
            id: 1, entityID: "p1", entityKind: "profile",
            kind: .fieldValue, field: field, reason: .valueMismatch,
            severity: .conflict, detectedBy: .consistencySweep,
            competingSources: [], evidenceJSON: nil,
            ladderTrace: nil, witnessSummary: nil,
            detectedAt: Date(), resolution: resolution,
            resolvedAt: resolution == nil ? nil : Date())
    }

    // MARK: - AC1: rival confirmed clusters hold criterion 4 unmet

    @Test func rivalConfirmedClustersHoldCriterion4UnmetNamingBothYears() {
        // The John 1840/41 pair: two clusters, each confirmed by a fact
        // record, asserting different birth years (DS-07/DS-14's
        // previously-unreachable branch).
        let c1840 = LifeCluster(
            id: "c1", records: [birthRecord("r1", year: 1840)],
            lifespanStart: 1840, lifespanEnd: 1950)
        let c1841 = LifeCluster(
            id: "c2", records: [birthRecord("r2", year: 1841)],
            lifespanStart: 1841, lifespanEnd: 1951)
        let gps = GPSScorer.score(
            result: result(facts: [], clusters: [c1840, c1841]),
            sourceInfoMap: [:], searchedSourceCount: 3, totalSourceCount: 7)
        let c4 = gps.criteria.first { $0.criterion == .conflictResolution }
        #expect(c4?.met == false)
        #expect(c4?.reason.contains("1840") == true)
        #expect(c4?.reason.contains("1841") == true)
    }

    @Test func openDisputeHoldsCriterion4Unmet() {
        let gps = GPSScorer.score(
            result: result(), sourceInfoMap: [:],
            searchedSourceCount: 3, totalSourceCount: 7,
            openDisputes: [disputeRow()])
        let c4 = gps.criteria.first { $0.criterion == .conflictResolution }
        #expect(c4?.met == false)
        #expect(c4?.reason.contains("deathDate") == true)
    }

    // MARK: - AC2: rule-resolved conflict reports met WITH the rule cited

    @Test func ruleResolvedDisputeReportsMetWithRuleID() {
        let resolved = disputeRow(
            field: "deathDate",
            resolution: .rule(id: "R2a", accepted: FieldSource(
                origin: SourceOrigin(identifier: "cwgc"), raw: "1917", addedAt: Date())))
        let gps = GPSScorer.score(
            result: result(), sourceInfoMap: [:],
            searchedSourceCount: 3, totalSourceCount: 7,
            resolvedDisputes: [resolved])
        let c4 = gps.criteria.first { $0.criterion == .conflictResolution }
        #expect(c4?.met == true)
        #expect(c4?.reason.contains("R2a") == true)
        #expect(c4?.reason.contains("deathDate") == true)
    }

    // MARK: - AC3: contradicting values no longer pool (DS-24)

    @Test func contradictingBirthValuesReportPerValueLevelsNotPooled() {
        // DS-24 fixture: birth 1881 + census-implied 1895 — previously
        // pooled into one convergence level; now each value group is
        // scored on its own records.
        let facts = [
            birthRecord("b1", year: 1881),
            censusRecord("c1", impliedBirth: 1895),
        ]
        let gps = GPSScorer.score(
            result: result(facts: facts), sourceInfoMap: [:],
            searchedSourceCount: 3, totalSourceCount: 7)
        let c3 = gps.criteria.first { $0.criterion == .analysisCorrelation }
        #expect(c3?.reason.contains("birth:1881") == true)
        #expect(c3?.reason.contains("birth:1895") == true)

        // And directly: the value groups are disjoint.
        let groups = ConvergenceEngine.scoreValueGroups(
            records: facts.map(\.record), sourceInfoMap: [:])
        #expect(groups.count == 2)
        #expect(Set(groups.map(\.key)) == ["birth:1881", "birth:1895"])
    }

    // MARK: - AC4: run discrepancies persist + open disputes

    @Test func runDiscrepanciesPersistWithRunIDAndConflictGradeOpensDispute() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        let profile = Profile(
            id: "p1", externalIDs: [:], firstName: "John", lastName: "Smith",
            gender: .male, attributes: nil, birthDate: nil, birthLocation: nil,
            deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
            sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)

        let discrepancy = ResearchDiscrepancy(
            field: "deathYear", existingValue: "1901", sourceValue: "1907",
            sourceID: "freebmd", severity: .conflict,
            reasoning: "disjoint death years")
        try db.insertRunDiscrepancies(
            profileID: "p1", runID: "run-1", discrepancies: [discrepancy])
        let persisted = try db.runDiscrepancies(runID: "run-1")
        #expect(persisted.count == 1)
        #expect(persisted.first?.field == "deathYear")

        // The ≥ .conflict discrepancy expressed as a runSweep dispute joins
        // the apply-path identity (field maps deathYear → deathDate).
        let conflict = ResearchRunService.disputeConflict(for: discrepancy, profileID: "p1")
        #expect(conflict.field == ProfileField.deathDate.rawValue)
        #expect(conflict.detectedBy == .runSweep)
        _ = try db.upsertDispute(
            profileID: "p1", conflict: conflict,
            adjudication: DisputeResolver.adjudicate(conflict))
        let open = try db.openDisputes(profileID: "p1")
        #expect(open.contains { $0.field == "deathDate" && $0.detectedBy == .runSweep })
    }

    // MARK: - AC5: the .conflict friction tier is reachable

    @Test func conflictFrictionTierReachableViaOpenDisputeSignal() {
        // An open dispute on the subject routes findings to .conflict —
        // the DS-14 unreachable-tier fix.
        #expect(FrictionTier.route(
            hasImpossible: false, hasFacts: true,
            recordCount: 3, hasConflictSignal: true) == .conflict)
        // Legacy mapping preserved when no signal.
        #expect(FrictionTier.route(
            hasImpossible: false, hasFacts: true,
            recordCount: 3, hasConflictSignal: false) == .refinement)
        #expect(FrictionTier.route(
            hasImpossible: true, hasFacts: true,
            recordCount: 3, hasConflictSignal: false) == .conflict)
        #expect(FrictionTier.route(
            hasImpossible: false, hasFacts: false,
            recordCount: 2, hasConflictSignal: false) == .correction)
        #expect(FrictionTier.route(
            hasImpossible: false, hasFacts: true,
            recordCount: 1, hasConflictSignal: false) == .confirmation)
    }
}
