import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// Reading a CANDIDATE census's household before applying it.
///
/// Owner dogfood 2026-08-22. Samuel Holmes carries three mutually exclusive
/// 1861 censuses — Matlock, Rowsley, Derby St Werburgh — and picking the right
/// one is a household question: the page names the parents and siblings of a
/// 14-year-old. Until this change the profile ledger offered only View / Apply
/// / Reject, so the sole route to any household was to APPLY a record and read
/// the evidence afterwards — writing a birth year and birthplace onto the
/// profile in order to discover they were wrong.
///
/// These pin the two halves: the ledger row carries the roster (and says when
/// one could still be fetched), and fetching a candidate's roster can never
/// come to rest on a DIFFERENT census's life event.
@MainActor
struct CensusCandidateHouseholdTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(
                sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)",
                arguments: [Date()])
        }
        return db
    }

    private func member(_ name: String, _ relationship: String, age: Int?,
                        birthPlace: String? = nil, isTarget: Bool = false) -> HouseholdMember {
        HouseholdMember(
            name: name, relationship: relationship, age: age,
            birthYear: nil, birthPlace: birthPlace, occupation: nil, sex: nil,
            maritalStatus: nil, birthCounty: nil, disability: nil, notes: nil,
            isTarget: isTarget)
    }

    private func census(_ id: String, year: Int = 1861,
                        detailURL: String? = "https://freecen/\(UUID().uuidString)",
                        household: [HouseholdMember]? = nil) -> ScoredRecord {
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", name: "Samuel HOLMES",
                                 surname: "HOLMES", givenName: "Samuel",
                                 detailURL: detailURL, rawFields: [:]),
            censusYear: year, age: 14, birthYear: year - 14,
            birthPlace: "Rowsley", district: "Bakewell", household: household))
        return ScoredRecord(id: id, record: record, verdict: .lead, gates: [], summary: "")
    }

    // MARK: - The ledger row carries the household

    /// A roster-less census with a detail page is the "Load household" case.
    @Test func candidateCensusWithoutARosterOffersTheFetch() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        try db.saveEvidence(profileID: "sam", scored: census("c1"),
                            citationFull: "FreeCen, Samuel HOLMES, Bakewell.",
                            citationURL: "https://freecen/c1")

        let records = try ProfileSourcesLedger.allRecords(for: "sam", db: db)
        let row = try #require(records.first)
        #expect(row.canLoadHousehold,
                "a census with a detail page and no roster is exactly the fetchable case")
        #expect(row.household.isEmpty)
    }

    /// Once fetched, the roster rides on the ledger row so the view can show it
    /// WITHOUT the record having been applied.
    @Test func candidateCensusWithARosterCarriesItUnapplied() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        let roster = [
            member("John HOLMES", "Head", age: 40),
            member("Ann HOLMES", "Wife", age: 38),
            member("Samuel HOLMES", "Son", age: 14, birthPlace: "Rowsley", isTarget: true),
        ]
        try db.saveEvidence(profileID: "sam", scored: census("c1", household: roster),
                            citationFull: "FreeCen, Samuel HOLMES, Bakewell.",
                            citationURL: "https://freecen/c1")

        let records = try ProfileSourcesLedger.allRecords(for: "sam", db: db)
        let row = try #require(records.first)
        #expect(row.standing == .researched, "precondition: NOT applied")
        #expect(row.household.count == 3,
                "the household must be readable before the record is applied — that is the whole point")
        #expect(!row.canLoadHousehold, "nothing left to fetch")
        #expect(row.household.contains { $0.isTarget == true },
                "the searched-for row is marked, so the house is read against the right member")
    }

    /// Non-census records never offer it.
    @Test func aBirthRecordOffersNoHousehold() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        let birth = ScoredRecord(
            id: "b1",
            record: .birth(BirthRecord(
                common: RecordCommon(id: "b1", sourceID: "freebmd", name: "Samuel Holmes",
                                     surname: "Holmes", givenName: "Samuel",
                                     detailURL: "https://freebmd/b1", rawFields: [:]),
                birthYear: 1845)),
            verdict: .lead, gates: [], summary: "")
        try db.saveEvidence(profileID: "sam", scored: birth,
                            citationFull: "FreeBMD.", citationURL: "https://freebmd/b1")

        let row = try #require(try ProfileSourcesLedger.allRecords(for: "sam", db: db).first)
        #expect(!row.canLoadHousehold)
        #expect(row.household.isEmpty)
    }

    /// A census with no detail page can't be fetched — no dead button.
    @Test func aCensusWithNoDetailPageIsNotFetchable() {
        #expect(!ProfileSourcesLedger.censusNeedsHousehold(census("c1", detailURL: nil).record))
        #expect(!ProfileSourcesLedger.censusNeedsHousehold(census("c1", detailURL: "").record))
    }

    /// `AppState` and the ledger must agree — there is one definition, and the
    /// three existing call sites go through the forwarder.
    @Test func appStateAndLedgerAgreeOnFetchability() {
        for rec in [census("c1").record,
                    census("c2", household: [member("A", "Head", age: 40)]).record,
                    census("c3", detailURL: nil).record] {
            #expect(AppState.censusNeedsHousehold(rec) == ProfileSourcesLedger.censusNeedsHousehold(rec),
                    "one predicate, or the button and the fetch will disagree")
        }
    }

    // MARK: - Collapsing twins must not hide a roster

    /// Two re-scrapes of the same census collapse to one row. If only one copy
    /// was enriched, the survivor inherits its household — otherwise loading a
    /// household would appear to do nothing.
    @Test func collapsingRescrapedTwinsKeepsTheRoster() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "sam", firstName: "Samuel", lastName: "Holmes",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        let citation = "\"1861 England Census,\" FreeCen, Samuel HOLMES, Bakewell"
        // Same citation bar the access date → same identity, two rows.
        try db.saveEvidence(profileID: "sam", scored: census("c1"),
                            citationFull: citation + "; accessed 21 Aug 2026.",
                            citationURL: "https://freecen/c1")
        try db.saveEvidence(
            profileID: "sam",
            scored: census("c2", household: [
                member("John HOLMES", "Head", age: 40),
                member("Samuel HOLMES", "Son", age: 14, isTarget: true),
            ]),
            citationFull: citation + "; accessed 22 Aug 2026.",
            citationURL: "https://freecen/c2")

        let records = try ProfileSourcesLedger.allRecords(for: "sam", db: db)
        #expect(records.count == 1, "twins collapse to one card")
        let row = try #require(records.first)
        #expect(row.household.count == 2,
                "the enriched twin's roster must survive the collapse")
        #expect(!row.canLoadHousehold,
                "and the row must not still offer a fetch it has already done")
    }

    // MARK: - A candidate's roster must not land on another census's event

    /// The regression this change could have introduced. Two 1861 candidates;
    /// one is applied and has a life event. Fetching the OTHER one's household
    /// must not fill the applied census's roster — that would silently attach a
    /// namesake's parents and siblings to the profile's real census.
    ///
    /// Pinned at the matching rule rather than through the network fetch: the
    /// event a record may fill is the one its own deterministic id names.
    @Test func aCandidatesRosterTargetsOnlyItsOwnEvent() {
        let appliedEvent = SourceRecord.deterministicID(profileID: "sam", sourceRecordID: "applied-1861")
        let candidateEvent = SourceRecord.deterministicID(profileID: "sam", sourceRecordID: "candidate-1861")
        #expect(appliedEvent != candidateEvent,
                "two censuses of the SAME YEAR must project to different events, or a year-match confuses them")
    }

    /// And the same record always names the same event, so the applied path
    /// (apply → fetch → fold) still finds its own roster slot.
    @Test func aRecordAlwaysNamesTheSameEvent() {
        let a = SourceRecord.deterministicID(profileID: "sam", sourceRecordID: "c1")
        let b = SourceRecord.deterministicID(profileID: "sam", sourceRecordID: "c1")
        #expect(a == b)
        #expect(a != SourceRecord.deterministicID(profileID: "other", sourceRecordID: "c1"),
                "and it is scoped to the profile")
    }
}
