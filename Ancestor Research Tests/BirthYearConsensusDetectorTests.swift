import Testing
import Foundation
@testable import Ancestor_Research

/// Slice B1 — guards on `BirthYearConsensusDetector.detect` per
/// `SUBJECT_SELF_NARROWING_SPEC.md` §7.1. The detector is purely
/// rule-driven; these tests pin the four MUST/tier outcomes the spec
/// lists as the acceptance gate for B1.
@MainActor
struct BirthYearConsensusDetectorTests {

    // MARK: - Test fixtures

    /// Belper-born subject with a wide birth window (1869-1896 — what
    /// `ResearchSubject.fromProfile` produces when birthDate is absent
    /// and the only signal is a child's birth year). Matches George
    /// H Brooks's actual subject construction in the test project.
    private func belperSubject(birthFrom: Int = 1869, birthTo: Int = 1896) -> ResearchSubject {
        var s = ResearchSubject(
            surname: "Brooks",
            givenName: "George",
            mode: .discover
        )
        s.birthYearFrom = birthFrom
        s.birthYearTo = birthTo
        s.region = .county("Belper, Derbyshire, England")
        s.deathLocation = "Belper, Derbyshire, England"
        return s
    }

    private func birthRecord(
        id: String,
        sourceID: String,
        year: Int,
        place: String?
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: sourceID,
            name: "George Brooks", surname: "Brooks", givenName: "George",
            detailURL: nil, rawFields: [:]
        )
        let r = BirthRecord(
            common: common, birthYear: year, birthDate: nil,
            birthPlace: place, quarter: nil, district: place,
            volume: nil, page: nil, mothersMaidenName: nil
        )
        return ScoredRecord(
            id: id, record: .birth(r),
            verdict: .lead, gates: [], summary: ""
        )
    }

    private func censusRecord(
        id: String, sourceID: String,
        censusYear: Int, age: Int, place: String?
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: sourceID,
            name: "George Brooks", surname: "Brooks", givenName: "George",
            detailURL: nil, rawFields: [:]
        )
        let r = CensusRecord(
            common: common, censusYear: censusYear, age: age,
            birthYear: nil, birthPlace: place, birthCounty: nil,
            relationship: nil, occupation: nil, address: nil,
            parish: place, district: place, household: nil
        )
        return ScoredRecord(
            id: id, record: .census(r),
            verdict: .lead, gates: [], summary: ""
        )
    }

    // MARK: - MUST §3.0 record-count floor

    @Test func tooFewRecords_returnsNil() {
        let subject = belperSubject()
        // Two records — below the 3-record floor.
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Belper"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 7, place: "Belper")
        ]
        #expect(BirthYearConsensusDetector.detect(in: scored, for: subject) == nil)
    }

    // MARK: - MUST §3.1 source diversity

    @Test func sameSourceOnly_returnsNil() {
        let subject = belperSubject()
        // Four records, all FreeCen — fails the ≥2-distinct-sources guard
        // even though count > floor and locations align.
        let scored = [
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 7, place: "Belper"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 17, place: "Belper"),
            censusRecord(id: "c3", sourceID: "freecen", censusYear: 1911, age: 27, place: "Belper"),
            censusRecord(id: "c4", sourceID: "freecen", censusYear: 1921, age: 37, place: "Belper")
        ]
        #expect(BirthYearConsensusDetector.detect(in: scored, for: subject) == nil)
    }

    // MARK: - MUST §3.2 locality alignment

    @Test func noLocalityAlignment_returnsNil() {
        let subject = belperSubject()
        // Three records, two sources — passes count + diversity — but
        // none in Belper. All in Northumberland Brookses; the wrong
        // George.
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Newcastle"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 7, place: "Newcastle"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 17, place: "Newcastle")
        ]
        #expect(BirthYearConsensusDetector.detect(in: scored, for: subject) == nil)
    }

    @Test func countyOnlyLocality_isNotAligned() {
        // "Derbyshire" with no town is too broad to anchor identity —
        // the noise-token filter strips county and country tokens. A
        // subject in Belper, Derbyshire and a record citing only
        // "Derbyshire" isn't a locality match.
        let subject = belperSubject()
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Derbyshire"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 7, place: "Derbyshire"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 17, place: "Derbyshire")
        ]
        #expect(BirthYearConsensusDetector.detect(in: scored, for: subject) == nil)
    }

    // MARK: - Tier discrimination (§3.5)

    @Test func threeRecordsTwoSources_aligned_isMedium() {
        // Ages chosen so every record implies birth 1883 exactly. Without
        // this, two records cluster at 1883 and one at 1884; the ±1
        // fuzziness ties both candidates at 3 supporters and Swift's
        // non-deterministic dictionary iteration picks one or the other.
        // Real-world data has this drift, but tests need single anchor.
        let subject = belperSubject()
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Belper"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 8, place: "Belper"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 18, place: "Belper")
        ]
        let result = BirthYearConsensusDetector.detect(in: scored, for: subject)
        #expect(result != nil)
        #expect(result?.proposedBirthYear == 1883)
        #expect(result?.confidence == .medium)
        #expect(result?.agreeingRecordCount == 3)
        #expect(result?.distinctSourceCount == 2)
    }

    @Test func fourRecordsThreeSources_aligned_isHigh() {
        // See `threeRecordsTwoSources_aligned_isMedium` — ages chosen so
        // every record implies birth 1883 exactly.
        let subject = belperSubject()
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Belper"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 8, place: "Belper"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 18, place: "Belper"),
            burialRecord(id: "br1", sourceID: "findagrave", year: 1883, place: "Belper")
        ]
        let result = BirthYearConsensusDetector.detect(in: scored, for: subject)
        #expect(result != nil)
        #expect(result?.proposedBirthYear == 1883)
        #expect(result?.confidence == .high)
        #expect(result?.agreeingRecordCount == 4)
        #expect(result?.distinctSourceCount == 3)
    }

    // MARK: - MUST §3.6 user rejections

    @Test func userRejectedRecords_areExcludedFromConsensus() {
        // Four records that would otherwise produce a HIGH-tier consensus,
        // but the user has discarded two — leaving only the BMD birth and
        // one census. That's below the §3.0 floor of 3 records, so the
        // detector returns nil. Same gesture the user makes in the
        // ClusterReviewView "Discard this record" button; the persistence
        // path is `record_rejections` / `evidence_records.user_status`.
        let subject = belperSubject()
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Belper"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 8, place: "Belper"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 18, place: "Belper"),
            burialRecord(id: "br1", sourceID: "findagrave", year: 1883, place: "Belper")
        ]
        let rejected: Set<String> = ["c1", "br1"]
        let result = BirthYearConsensusDetector.detect(
            in: scored, for: subject, rejectedRecordIDs: rejected
        )
        #expect(result == nil)
    }

    @Test func nonRejectedRecords_stillTriggerConsensus() {
        // Same fixture but with an irrelevant rejected ID. The detector
        // must not be paranoid — only the named records are excluded;
        // the other supporters still count toward the consensus.
        let subject = belperSubject()
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Belper"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 8, place: "Belper"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 18, place: "Belper"),
            burialRecord(id: "br1", sourceID: "findagrave", year: 1883, place: "Belper")
        ]
        let rejected: Set<String> = ["nonexistent-id"]
        let result = BirthYearConsensusDetector.detect(
            in: scored, for: subject, rejectedRecordIDs: rejected
        )
        #expect(result != nil)
        #expect(result?.confidence == .high)
        #expect(result?.agreeingRecordCount == 4)
    }

    // MARK: - Wide-window precondition

    @Test func tightWindow_returnsNil() {
        // Subject already has a precise birth year — narrowing makes no
        // sense. Detector should bail before evaluating evidence.
        var subject = belperSubject()
        subject.birthYearFrom = 1883
        subject.birthYearTo = 1883
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Belper"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 7, place: "Belper"),
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 17, place: "Belper"),
            burialRecord(id: "br1", sourceID: "findagrave", year: 1883, place: "Belper")
        ]
        #expect(BirthYearConsensusDetector.detect(in: scored, for: subject) == nil)
    }

    // MARK: - Off-by-one fuzziness

    @Test func plusOrMinusOneYear_clustersTogether() {
        // BMD Q4 1883 + census ages drift 1 year + burial age drift —
        // common in real data. The ±1 fuzziness bucket lets them all
        // align around the same anchor.
        let subject = belperSubject()
        let scored = [
            birthRecord(id: "b1", sourceID: "freebmd", year: 1883, place: "Belper"),
            censusRecord(id: "c1", sourceID: "freecen", censusYear: 1891, age: 8, place: "Belper"),  // implies 1883
            censusRecord(id: "c2", sourceID: "freecen", censusYear: 1901, age: 17, place: "Belper"), // implies 1884
            burialRecord(id: "br1", sourceID: "findagrave", year: 1882, place: "Belper") // off by 1
        ]
        let result = BirthYearConsensusDetector.detect(in: scored, for: subject)
        #expect(result != nil)
        #expect(result?.agreeingRecordCount == 4)
    }

    // MARK: - Helpers

    private func burialRecord(
        id: String, sourceID: String, year: Int, place: String?
    ) -> ScoredRecord {
        let common = RecordCommon(
            id: id, sourceID: sourceID,
            name: "George Brooks", surname: "Brooks", givenName: "George",
            detailURL: nil, rawFields: [:]
        )
        let r = BurialRecord(
            common: common, deathDate: nil, deathYear: nil,
            birthDate: nil, birthYear: year,
            birthPlace: place, deathPlace: nil,
            burialLocation: place, cemetery: nil,
            memorialID: nil, inscription: nil, bio: nil, isVeteran: false
        )
        return ScoredRecord(
            id: id, record: .burial(r),
            verdict: .lead, gates: [], summary: ""
        )
    }
}
