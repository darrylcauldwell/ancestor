import Testing
import Foundation
@testable import Ancestor_Research

/// Tests that the deterministic engine always has final say over the reasoning model.
/// These enforce the boundary: the model suggests, deterministic decides.
struct DeterminismBoundaryTests {

    // MARK: - Helpers

    private func makeCommon(
        id: String = UUID().uuidString,
        sourceID: String = "freebmd",
        surname: String? = "LAND",
        givenName: String? = "THOMAS"
    ) -> RecordCommon {
        RecordCommon(
            id: id, sourceID: sourceID, name: nil,
            surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
    }

    private func scored(
        _ record: SourceRecord,
        verdict: RecordVerdict = .fact
    ) -> ScoredRecord {
        ScoredRecord(
            id: record.id, record: record,
            verdict: verdict, gates: [], summary: ""
        )
    }

    private let sourceInfoMap: [String: SourceInfo] = [
        "freebmd": SourceInfo(
            sourceID: "freebmd",
            lineage: .independentTranscription(of: "GRO-indexes"),
            trustTier: .transcription,
            directness: .directTranscription
        ),
    ]

    // MARK: - Impossible records cannot be promoted

    @Test func impossibleRecordExcludedFromClusters() {
        // An impossible record should never appear in any cluster,
        // regardless of what a reasoning model might suggest
        let impossible = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1700,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )), verdict: .impossible)

        let fact = scored(.birth(BirthRecord(
            common: makeCommon(id: "b2"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))

        let clusters = ClusteringEngine.cluster(
            records: [impossible, fact], sourceInfoMap: sourceInfoMap
        )

        // The impossible record must not appear in any cluster
        let allRecordIDs = clusters.flatMap { $0.records.map(\.id) }
        #expect(!allRecordIDs.contains("b1"))
        #expect(allRecordIDs.contains("b2"))
    }

    // MARK: - Scorer gates are deterministic

    @Test func nameMismatchAlwaysFails() {
        // A name gate failure cannot be overridden
        let subject = ResearchSubject(
            surname: "CAULDWELL", givenName: "ROBERT",
            birthYearFrom: 1834, birthYearTo: 1834,
            gender: .male, region: .englandAndWales, mode: .extend
        )

        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(
                id: "test", sourceID: "freebmd", name: nil,
                surname: "SMITH", givenName: "JAMES",
                detailURL: nil, rawFields: [:]
            ),
            birthYear: 1834, birthDate: nil, birthPlace: nil,
            quarter: nil, district: "Bakewell", volume: nil,
            page: nil, mothersMaidenName: nil
        ))

        let result = RecordScorer.classify(
            record: record, subject: subject, searchType: .birth
        )

        // Name mismatch must produce impossible verdict — no override possible
        #expect(result.verdict == .impossible)
    }

    // MARK: - Date impossibility is absolute

    @Test func temporalImpossibilityCannotBeOverridden() {
        let subject = ResearchSubject(
            surname: "LAND", givenName: "THOMAS",
            birthYearFrom: 1834, birthYearTo: 1834,
            gender: .male, region: .englandAndWales, mode: .extend
        )

        // Marriage before age 16 is impossible
        let record = SourceRecord.marriage(MarriageRecord(
            common: makeCommon(id: "m1"), marriageYear: 1840,
            marriageDate: nil, marriagePlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, spouseName: nil
        ))

        let result = RecordScorer.classify(
            record: record, subject: subject, searchType: .marriage
        )

        // Married at age 6 — impossible, no model override
        #expect(result.verdict == .impossible)
    }

    // MARK: - Convergence is deterministic

    @Test func allDerivativeSourcesCappedAtPossible() {
        // Even if a reasoning model says "confirmed", derivative-only
        // evidence cannot exceed .possible
        let records: [SourceRecord] = [
            .burial(BurialRecord(
                common: RecordCommon(id: "1", sourceID: "findagrave", name: nil,
                    surname: "LAND", givenName: "THOMAS", detailURL: nil, rawFields: [:]),
                deathDate: nil, deathYear: 1890, birthDate: nil, birthYear: 1834,
                burialLocation: "Belper", cemetery: "Test Cemetery",
                memorialID: 1, inscription: nil, bio: nil, isVeteran: false
            )),
            .burial(BurialRecord(
                common: RecordCommon(id: "2", sourceID: "findagrave", name: nil,
                    surname: "LAND", givenName: "THOMAS", detailURL: nil, rawFields: [:]),
                deathDate: nil, deathYear: 1890, birthDate: nil, birthYear: 1834,
                burialLocation: "Belper", cemetery: "Another Cemetery",
                memorialID: 2, inscription: nil, bio: nil, isVeteran: false
            )),
        ]

        let derivativeOnly: [String: SourceInfo] = [
            "findagrave": SourceInfo(
                sourceID: "findagrave",
                lineage: .communityEdited,
                trustTier: .community,
                directness: .derivative
            ),
        ]

        let convergence = ConvergenceEngine.score(
            records: records, sourceInfoMap: derivativeOnly
        )

        // All derivative → capped at .possible, cannot be .confirmed
        #expect(convergence <= .possible)
    }

    // MARK: - Evidence summary fallback works without model

    @Test func deterministicEvidenceSummaryAlwaysAvailable() {
        let cluster = LifeCluster(
            id: "test",
            records: [
                scored(.birth(BirthRecord(
                    common: makeCommon(id: "b1"), birthYear: 1834,
                    birthDate: nil, birthPlace: nil, quarter: "Mar",
                    district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
                ))),
            ],
            confidence: .weak,
            lifespanStart: 1834, lifespanEnd: 1944
        )
        let subject = ResearchSubject(
            surname: "LAND", givenName: "THOMAS",
            birthYearFrom: 1834, birthYearTo: 1834,
            gender: .male, region: .englandAndWales, mode: .extend
        )

        let summary = ResearchInterpreter.deterministicEvidenceSummary(
            cluster: cluster, subject: subject, sourceInfoMap: sourceInfoMap
        )

        // Must always produce a non-empty summary
        #expect(!summary.isEmpty)
        #expect(summary.contains("1834"))
    }
}
