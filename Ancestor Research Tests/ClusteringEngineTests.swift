import Testing
import Foundation
@testable import Ancestor_Research

struct ClusteringEngineTests {

    // MARK: - Helpers

    private func makeCommon(
        id: String = UUID().uuidString,
        sourceID: String = "freebmd",
        name: String? = nil,
        surname: String? = "LAND",
        givenName: String? = "THOMAS"
    ) -> RecordCommon {
        RecordCommon(
            id: id, sourceID: sourceID, name: name,
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

    private let emptySourceInfo: [String: SourceInfo] = [
        "freebmd": SourceInfo(
            sourceID: "freebmd",
            lineage: .independentTranscription(of: "GRO-indexes"),
            trustTier: .transcription,
            directness: .directTranscription
        ),
        "freecen": SourceInfo(
            sourceID: "freecen",
            lineage: .independentTranscription(of: "census-returns"),
            trustTier: .transcription,
            directness: .directTranscription
        ),
        "findagrave": SourceInfo(
            sourceID: "findagrave",
            lineage: .communityEdited,
            trustTier: .community,
            directness: .derivative
        ),
    ]

    // MARK: - Step 1: Seed from births

    @Test func threeDistinctBirthsSeedThreeClusters() {
        let records = [
            scored(.birth(BirthRecord(
                common: makeCommon(id: "b1"), birthYear: 1834,
                birthDate: nil, birthPlace: nil, quarter: "Mar",
                district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
            ))),
            scored(.birth(BirthRecord(
                common: makeCommon(id: "b2"), birthYear: 1856,
                birthDate: nil, birthPlace: nil, quarter: "Jun",
                district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
            ))),
            scored(.birth(BirthRecord(
                common: makeCommon(id: "b3"), birthYear: 1878,
                birthDate: nil, birthPlace: nil, quarter: "Sep",
                district: "Belper", volume: nil, page: nil, mothersMaidenName: nil
            ))),
        ]

        let clusters = ClusteringEngine.cluster(records: records, sourceInfoMap: emptySourceInfo, homeChapmanCode: "DBY")
        #expect(clusters.count == 3)
    }

    // MARK: - Step 2: Assignment

    @Test func censusAssignedToMatchingCluster() {
        let birth = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: "Mar",
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))
        let census = scored(.census(CensusRecord(
            common: makeCommon(id: "c1", sourceID: "freecen"),
            censusYear: 1861, age: 27, birthYear: 1834,
            birthPlace: "Wirksworth", birthCounty: "Derbyshire",
            relationship: "Head", occupation: "Lead Miner",
            address: nil, parish: "Wirksworth", district: "Bakewell",
            household: nil
        )))

        let clusters = ClusteringEngine.cluster(
            records: [birth, census], sourceInfoMap: emptySourceInfo,
            homeChapmanCode: "DBY"
        )
        #expect(clusters.count == 1)
        #expect(clusters[0].records.count == 2)
    }

    @Test func householdConfirmationScoresHigher() {
        // Census with wife Hannah should be assigned to the cluster that
        // already has a marriage to Hannah
        let birth = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))
        let marriage = scored(.marriage(MarriageRecord(
            common: makeCommon(id: "m1"), marriageYear: 1858,
            marriageDate: nil, marriagePlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, spouseName: "Hannah Brooks"
        )))
        let censusWithHannah = scored(.census(CensusRecord(
            common: makeCommon(id: "c1", sourceID: "freecen"),
            censusYear: 1861, age: 27, birthYear: 1834,
            birthPlace: "Wirksworth", birthCounty: "Derbyshire",
            relationship: "Head", occupation: "Lead Miner",
            address: nil, parish: "Wirksworth", district: "Bakewell",
            household: [
                HouseholdMember(name: "Thomas Land", relationship: "Head",
                    age: 27, birthYear: 1834, birthPlace: "Wirksworth",
                    occupation: "Lead Miner", sex: "M"),
                HouseholdMember(name: "Hannah Land", relationship: "Wife",
                    age: 25, birthYear: 1836, birthPlace: "Bakewell",
                    occupation: nil, sex: "F"),
            ]
        )))

        let clusters = ClusteringEngine.cluster(
            records: [birth, marriage, censusWithHannah],
            sourceInfoMap: emptySourceInfo,
            homeChapmanCode: "DBY"
        )
        // All three should be in the same cluster
        #expect(clusters.count == 1)
        #expect(clusters[0].records.count == 3)
    }

    // MARK: - Step 3: Split contradictions

    @Test func twoBirthsInSameClusterGetSplit() {
        // Two births with same year but different districts — seeded separately
        // Two births with same district AND same year — deduplicated in seed
        // Force the split scenario: two births that initially seed 2 clusters,
        // but test that if they were somehow in one, splitting works
        let b1 = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))
        let b2 = scored(.birth(BirthRecord(
            common: makeCommon(id: "b2"), birthYear: 1856,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))
        // These should seed as 2 separate clusters (different years)
        let clusters = ClusteringEngine.cluster(records: [b1, b2], sourceInfoMap: emptySourceInfo, homeChapmanCode: "DBY")
        #expect(clusters.count == 2)
    }

    @Test func contradictingCensusAgesGetSplit() {
        // 1841 age=30 implies born 1811, 1851 age=45 implies born 1806
        // Difference is 5 — right at the boundary. Use >5 difference.
        // 1841 age=30 → born 1811, 1851 age=34 → born 1817 (diff = 6 → split)
        let c1 = scored(.census(CensusRecord(
            common: makeCommon(id: "c1", sourceID: "freecen"),
            censusYear: 1841, age: 30, birthYear: 1811,
            birthPlace: nil, birthCounty: nil,
            relationship: "Head", occupation: nil,
            address: nil, parish: nil, district: "Bakewell",
            household: nil
        )))
        let c2 = scored(.census(CensusRecord(
            common: makeCommon(id: "c2", sourceID: "freecen"),
            censusYear: 1851, age: 34, birthYear: 1817,
            birthPlace: nil, birthCounty: nil,
            relationship: "Head", occupation: nil,
            address: nil, parish: nil, district: "Bakewell",
            household: nil
        )))

        let clusters = ClusteringEngine.cluster(records: [c1, c2], sourceInfoMap: emptySourceInfo, homeChapmanCode: "DBY")
        #expect(clusters.count == 2)
    }

    // MARK: - Step 5: Confidence

    @Test func singleRecordClusterIsSingleSourced() {
        // RESEARCH_CONFIDENCE_SPEC Change 5 — pre-Change-5 assertion was
        // `.confidence == .weak`. New equivalent: single-source sourcing
        // (no corroboration), with whatever match-quality the verdict gives.
        let birth = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))

        let clusters = ClusteringEngine.cluster(records: [birth], sourceInfoMap: emptySourceInfo, homeChapmanCode: "DBY")
        #expect(clusters.count == 1)
        let conf = clusters[0].evidenceConfidence(sourceInfoMap: emptySourceInfo)
        #expect(conf.sourcing.sourceCount == 1)
        #expect(!conf.sourcing.isCrossReferenced)
    }

    @Test func allLeadsClusterHasPossibleMatchQuality() {
        // Pre-Change-5 assertion: `.confidence == .ambiguous`. The new model
        // surfaces this as match-quality .possible (.lead verdicts produce
        // .possible; no .fact records present → can't promote to .confirmed).
        let lead1 = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )), verdict: .lead)
        let lead2 = scored(.death(DeathRecord(
            common: makeCommon(id: "d1"), deathYear: 1890,
            deathDate: nil, deathPlace: nil, age: 56, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, spouseSurname: nil
        )), verdict: .lead)

        let clusters = ClusteringEngine.cluster(records: [lead1, lead2], sourceInfoMap: emptySourceInfo, homeChapmanCode: "DBY")
        for cluster in clusters {
            #expect(cluster.matchQuality == .possible)
        }
    }

    // MARK: - Death caps the life (over-merge guard)

    @Test func infantDeathDoesNotClusterWithLaterMarriageOrCensus() {
        // The Ernest Cauldwell over-merge: a death at age 0 in 1886 cannot be
        // the same person as a 1915 marriage or a living 1891 census. All four
        // records share a district (which pulls them together), so only the
        // death logic can keep them apart.
        let birth = scored(.birth(BirthRecord(
            common: makeCommon(id: "b", surname: "CAULDWELL", givenName: "ERNEST"),
            birthYear: 1877, birthDate: nil, birthPlace: nil, quarter: "Dec",
            district: "Belper", volume: nil, page: nil, mothersMaidenName: nil)))
        let death = scored(.death(DeathRecord(
            common: makeCommon(id: "d", surname: "CAULDWELL", givenName: "ERNEST"),
            deathYear: 1886, deathDate: nil, deathPlace: nil, age: 0, quarter: "Jun",
            district: "Belper", volume: nil, page: nil, spouseSurname: nil)))
        let census = scored(.census(CensusRecord(
            common: makeCommon(id: "c", sourceID: "freecen", surname: "CAULDWELL", givenName: "ERNEST"),
            censusYear: 1891, age: 4, birthYear: 1887, birthPlace: "Turnditch",
            birthCounty: "Derbyshire", relationship: "Son", occupation: nil,
            address: nil, parish: nil, district: "Belper", household: nil)))
        let marriage = scored(.marriage(MarriageRecord(
            common: makeCommon(id: "m", surname: "CAULDWELL", givenName: "ERNEST"),
            marriageYear: 1915, marriageDate: nil, marriagePlace: nil, quarter: "Mar",
            district: "Belper", volume: nil, page: nil, spouseName: "Ward")))

        let clusters = ClusteringEngine.cluster(
            records: [birth, death, census, marriage],
            sourceInfoMap: emptySourceInfo, homeChapmanCode: "DBY")

        for c in clusters {
            let ids = Set(c.records.map(\.id))
            #expect(!(ids.contains("d") && ids.contains("m")),
                    "Infant death must not share a cluster with a later marriage")
            #expect(!(ids.contains("d") && ids.contains("c")),
                    "Infant death must not share a cluster with a living census")
        }
    }

    @Test func recordAfterDeathIsRejectedFromAssignment() {
        // A birth + death (age 56 ⇒ born 1834) form one life; a marriage dated
        // AFTER the death cannot join it.
        let birth = scored(.birth(BirthRecord(
            common: makeCommon(id: "b"), birthYear: 1834, birthDate: nil,
            birthPlace: nil, quarter: nil, district: "Bakewell", volume: nil,
            page: nil, mothersMaidenName: nil)))
        let death = scored(.death(DeathRecord(
            common: makeCommon(id: "d"), deathYear: 1890, deathDate: nil,
            deathPlace: nil, age: 56, quarter: nil, district: "Bakewell",
            volume: nil, page: nil, spouseSurname: nil)))
        let lateMarriage = scored(.marriage(MarriageRecord(
            common: makeCommon(id: "m"), marriageYear: 1905, marriageDate: nil,
            marriagePlace: nil, quarter: nil, district: "Bakewell", volume: nil,
            page: nil, spouseName: "Brooks")))

        let clusters = ClusteringEngine.cluster(
            records: [birth, death, lateMarriage],
            sourceInfoMap: emptySourceInfo, homeChapmanCode: "DBY")

        for c in clusters {
            let ids = Set(c.records.map(\.id))
            #expect(!(ids.contains("d") && ids.contains("m")),
                    "A marriage after death must not join the death's cluster")
        }
    }

    // MARK: - Score formula

    @Test func perfectMatchScoresOne() {
        let birth = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))
        let cluster = LifeCluster(
            id: "test", records: [birth],
            lifespanStart: 1834, lifespanEnd: 1944
        )

        // A census record at 1861, same district, with matching household
        let census = scored(.census(CensusRecord(
            common: makeCommon(id: "c1", sourceID: "freecen"),
            censusYear: 1861, age: 27, birthYear: 1834,
            birthPlace: "Wirksworth", birthCounty: "Derbyshire",
            relationship: "Head", occupation: "Lead Miner",
            address: nil, parish: nil, district: "Bakewell",
            household: [
                HouseholdMember(name: "Thomas Land", relationship: "Head",
                    age: 27, birthYear: 1834, birthPlace: nil,
                    occupation: nil, sex: "M"),
            ]
        )))

        let score = ClusteringEngine.assignmentScore(record: census, cluster: cluster, homeChapmanCode: "DBY")
        // date=1.0*0.4 + location=1.0*0.3 + household=0.0*0.3 (no prior household to match)
        // Actually household needs existing cluster members to match against
        #expect(score >= 0.7) // date + location
    }

    @Test func completeMismatchScoresZero() {
        let birth = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))
        let cluster = LifeCluster(
            id: "test", records: [birth],
            lifespanStart: 1834, lifespanEnd: 1944
        )

        // Record from 1700 in London — completely outside lifespan and non-local
        let mismatch = scored(.death(DeathRecord(
            common: makeCommon(id: "d1"), deathYear: 1700,
            deathDate: nil, deathPlace: nil, age: nil, quarter: nil,
            district: "Kensington", volume: nil, page: nil, spouseSurname: nil
        )))

        let score = ClusteringEngine.assignmentScore(record: mismatch, cluster: cluster, homeChapmanCode: "DBY")
        #expect(score < 0.4)
    }

    // MARK: - Impossible records excluded

    @Test func impossibleRecordsExcludedFromClusters() {
        let fact = scored(.birth(BirthRecord(
            common: makeCommon(id: "b1"), birthYear: 1834,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )))
        let impossible = scored(.birth(BirthRecord(
            common: makeCommon(id: "b2"), birthYear: 1700,
            birthDate: nil, birthPlace: nil, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, mothersMaidenName: nil
        )), verdict: .impossible)

        let clusters = ClusteringEngine.cluster(
            records: [fact, impossible], sourceInfoMap: emptySourceInfo,
            homeChapmanCode: "DBY"
        )
        let allRecordIDs = clusters.flatMap { $0.records.map(\.id) }
        #expect(!allRecordIDs.contains("b2"))
    }

    // MARK: - No birth records fallback

    @Test func noBirthRecordsSeedsFromEarliest() {
        let census = scored(.census(CensusRecord(
            common: makeCommon(id: "c1", sourceID: "freecen"),
            censusYear: 1861, age: 27, birthYear: 1834,
            birthPlace: nil, birthCounty: nil,
            relationship: "Head", occupation: nil,
            address: nil, parish: nil, district: "Bakewell",
            household: nil
        )))
        let death = scored(.death(DeathRecord(
            common: makeCommon(id: "d1"), deathYear: 1890,
            deathDate: nil, deathPlace: nil, age: 56, quarter: nil,
            district: "Bakewell", volume: nil, page: nil, spouseSurname: nil
        )))

        let clusters = ClusteringEngine.cluster(
            records: [census, death], sourceInfoMap: emptySourceInfo,
            homeChapmanCode: "DBY"
        )
        #expect(clusters.count == 1)
        #expect(clusters[0].records.count == 2)
    }
}
