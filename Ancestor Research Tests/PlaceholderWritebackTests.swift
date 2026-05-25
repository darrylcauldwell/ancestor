import Testing
import Foundation
@testable import Ancestor_Research

/// ENGINE_FOUNDATION_SPEC #Change2 — consensus-based enrichment of
/// thin placeholder profiles after their first research round. Unit
/// tests cover the pure `propose` decision and the per-record-type
/// birth-year extractor. The DB-side `apply` is integration-tested
/// elsewhere (requires live SQLite + transactions).
struct PlaceholderWritebackTests {

    // MARK: - propose: consensus rules

    @Test func noProposalWhenTooFewRecords() {
        // 4 records — under minSupportingRecords (5).
        let records: [(givenName: String?, birthYear: Int?)] = [
            ("Jennifer", 1942), ("Jennifer", 1942), ("Jennifer", 1942), ("Jennifer", 1942)
        ]
        #expect(PlaceholderWriteback.propose(from: records) == nil)
    }

    @Test func proposalWhenStrongConsensus() {
        // 10 Jennifer + 1 Janet — 91% top, 9% runner-up.
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: ("Jennifer" as String?, 1942 as Int?), count: 10)
            + [("Janet", 1944)]
        let proposal = PlaceholderWriteback.propose(from: records)
        #expect(proposal != nil)
        #expect(proposal?.givenName == "Jennifer")
        #expect(proposal?.birthYearEarliest == 1942)
        #expect(proposal?.birthYearLatest == 1942)
        #expect(proposal?.supportingRecordCount == 10)
    }

    @Test func noProposalWhenRunnerUpTooLarge() {
        // 7 Jennifer + 3 Janet = 70% vs 30%. Floor 0.7 met, but
        // runner-up 0.3 > 0.2 ceiling. Refuse.
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: ("Jennifer" as String?, 1942 as Int?), count: 7)
            + Array(repeating: ("Janet" as String?, 1944 as Int?), count: 3)
        #expect(PlaceholderWriteback.propose(from: records) == nil)
    }

    @Test func noProposalWhenSplitEvenly() {
        // 5 Jennifer + 5 Janet — 50/50 split, neither dominates.
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: ("Jennifer" as String?, 1942 as Int?), count: 5)
            + Array(repeating: ("Janet" as String?, 1944 as Int?), count: 5)
        #expect(PlaceholderWriteback.propose(from: records) == nil)
    }

    @Test func noProposalWhenAllRecordsLackGivenName() {
        // 10 records, all with nil given_name — nothing to consensus on.
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: (nil as String?, 1942 as Int?), count: 10)
        #expect(PlaceholderWriteback.propose(from: records) == nil)
    }

    @Test func proposalFiltersOutNilGivenNamesFromCount() {
        // 10 Jennifer + 50 nil — nil records don't count toward
        // consensus denominator, so Jennifer is 100% of valid records.
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: ("Jennifer" as String?, 1942 as Int?), count: 10)
            + Array(repeating: (nil as String?, 1942 as Int?), count: 50)
        let proposal = PlaceholderWriteback.propose(from: records)
        #expect(proposal?.givenName == "Jennifer")
        #expect(proposal?.supportingRecordCount == 10)
    }

    @Test func proposalCaseInsensitiveGrouping() {
        // Mixed case forms (FreeBMD often returns ALL CAPS) cluster
        // as the same name; the result preserves the original casing.
        let records: [(givenName: String?, birthYear: Int?)] = [
            ("JENNIFER", 1942), ("Jennifer", 1942), ("jennifer", 1942),
            ("JENNIFER", 1942), ("Jennifer", 1942), ("Jennifer", 1942)
        ]
        let proposal = PlaceholderWriteback.propose(from: records)
        // First-seen casing wins — caller filed "JENNIFER" first.
        #expect(proposal?.givenName == "JENNIFER")
        #expect(proposal?.supportingRecordCount == 6)
    }

    @Test func proposalBirthYearWindowSpansSupportingRecords() {
        // 8 Jennifers across 1941-1943 — window narrows from a 30-year
        // placeholder estimate to the observed 3-year span.
        let records: [(givenName: String?, birthYear: Int?)] = [
            ("Jennifer", 1941), ("Jennifer", 1942), ("Jennifer", 1942),
            ("Jennifer", 1942), ("Jennifer", 1942), ("Jennifer", 1943),
            ("Jennifer", 1943), ("Jennifer", 1942)
        ]
        let proposal = PlaceholderWriteback.propose(from: records)
        #expect(proposal?.birthYearEarliest == 1941)
        #expect(proposal?.birthYearLatest == 1943)
    }

    @Test func proposalSkipsYearWindowWhenNoneCarryYears() {
        // Top name has no birth-year info on any supporting record —
        // proposal still fires (name is enough) but window is nil.
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: ("Jennifer" as String?, nil as Int?), count: 10)
        let proposal = PlaceholderWriteback.propose(from: records)
        #expect(proposal?.givenName == "Jennifer")
        #expect(proposal?.birthYearEarliest == nil)
        #expect(proposal?.birthYearLatest == nil)
    }

    @Test func proposalIgnoresWhitespaceOnlyGivenNames() {
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: ("Jennifer" as String?, 1942 as Int?), count: 10)
            + Array(repeating: ("   " as String?, 1942 as Int?), count: 50)
        let proposal = PlaceholderWriteback.propose(from: records)
        #expect(proposal?.givenName == "Jennifer")
        #expect(proposal?.supportingRecordCount == 10)
    }

    @Test func proposalSingleDominantNameAcrossManyOthers() {
        // 30 Jennifer, 1 Janet, 1 Mary, 1 Susan, 1 Patricia.
        // Top: 30/34 = 88% (floor 70% ✓). Runner-up: 1/34 = 3% (≤ 20% ✓).
        // Should fire.
        let records: [(givenName: String?, birthYear: Int?)] =
            Array(repeating: ("Jennifer" as String?, 1942 as Int?), count: 30)
            + [("Janet", 1944), ("Mary", 1940), ("Susan", 1942), ("Patricia", 1943)]
        let proposal = PlaceholderWriteback.propose(from: records)
        #expect(proposal?.givenName == "Jennifer")
        #expect(proposal?.supportingRecordCount == 30)
    }

    // MARK: - extractBirthYear: per-record-type

    @Test func extractBirthYearFromBirthRecord() {
        let record: SourceRecord = .birth(BirthRecord(
            common: testCommonFields("rec-b-1", surname: "Holmes", givenName: "Jennifer"),
            birthYear: 1942, birthDate: nil, birthPlace: nil,
            quarter: "Jun", district: "Belper", volume: "19", page: "438",
            mothersMaidenName: nil
        ))
        #expect(PlaceholderWriteback.extractBirthYear(from: record) == 1942)
    }

    @Test func extractBirthYearFromCensus() {
        let record: SourceRecord = .census(CensusRecord(
            common: testCommonFields("rec-c-1", surname: "Holmes", givenName: "Jennifer"),
            censusYear: 1951, age: 9, birthYear: 1942, birthPlace: nil,
            birthCounty: nil, relationship: nil, occupation: nil,
            address: nil, parish: nil, district: "Belper", household: nil
        ))
        #expect(PlaceholderWriteback.extractBirthYear(from: record) == 1942)
    }

    @Test func extractBirthYearFromBaptismParish() {
        let record: SourceRecord = .parish(ParishRecord(
            common: testCommonFields("rec-p-1", surname: "Holmes", givenName: "Jennifer"),
            eventType: "baptism", eventDate: nil, eventYear: 1942,
            parish: "Cromford", county: "DBY",
            fatherName: nil, motherName: nil
        ))
        #expect(PlaceholderWriteback.extractBirthYear(from: record) == 1942)
    }

    @Test func extractBirthYearFromMarriageReturnsNil() {
        // Marriage record carries the marriage year, not birth. Returns
        // nil so the proposal's year window isn't polluted.
        let record: SourceRecord = .marriage(MarriageRecord(
            common: testCommonFields("rec-m-1", surname: "Holmes", givenName: "Jennifer"),
            marriageYear: 1965, marriageDate: nil, marriagePlace: nil,
            quarter: nil, district: "Belper", volume: nil, page: nil,
            spouseName: nil
        ))
        #expect(PlaceholderWriteback.extractBirthYear(from: record) == nil)
    }

    @Test func extractBirthYearFromDeathReturnsNil() {
        let record: SourceRecord = .death(DeathRecord(
            common: testCommonFields("rec-d-1", surname: "Holmes", givenName: "Jennifer"),
            deathYear: 2023, deathDate: nil, deathPlace: nil, age: 81,
            quarter: nil, district: "Belper", volume: nil, page: nil,
            spouseSurname: nil
        ))
        #expect(PlaceholderWriteback.extractBirthYear(from: record) == nil)
    }

    // MARK: - Fixtures

    private func testCommonFields(_ id: String, surname: String, givenName: String) -> RecordCommon {
        RecordCommon(
            id: id, sourceID: "freebmd", name: nil,
            surname: surname, givenName: givenName,
            detailURL: nil, rawFields: [:]
        )
    }
}
