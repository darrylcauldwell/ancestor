import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// PROFILE_SOURCES_LEDGER_SPEC Change 2 — the read-only per-profile ledger:
/// kept records surface with what they establish, read from evidence_records
/// with no research run; discarded/unreviewed rows are excluded.
@MainActor
struct ProfileSourcesLedgerTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func birth(_ id: String, year: Int, quarter: String, district: String,
                       vol: String, page: String) -> ScoredRecord {
        let common = RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                  surname: "BROOKS", givenName: "GEORGE HERBERT",
                                  detailURL: nil, rawFields: [:])
        let record = SourceRecord.birth(BirthRecord(
            common: common, birthYear: year, birthDate: nil, birthPlace: district,
            quarter: quarter, district: district, volume: vol, page: page,
            mothersMaidenName: nil))
        return ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    @Test func ledgerListsKeptRecordsAndWhatTheyEstablish() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "p1", firstName: "George Herbert", lastName: "Brooks",
            gender: .male, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)

        let kept = birth("freebmd_birth_7a_631", year: 1883, quarter: "Dec",
                         district: "Belper", vol: "7a", page: "631")
        let discarded = birth("freebmd_birth_7a_602", year: 1884, quarter: "Mar",
                              district: "Belper", vol: "7a", page: "602")
        try db.saveEvidence(profileID: "p1", scored: kept,
                            citationFull: "FreeBMD, George Herbert Brooks, Dec 1883, Belper, 7a/631",
                            citationURL: "https://freebmd/631")
        try db.saveEvidence(profileID: "p1", scored: discarded,
                            citationFull: "FreeBMD, George Brooks, Mar 1884, Belper, 7a/602",
                            citationURL: nil)
        try db.updateEvidenceUserStatus(profileID: "p1", sourceRecordIDs: [kept.record.id], status: .savedAsLead)
        try db.updateEvidenceUserStatus(profileID: "p1", sourceRecordIDs: [discarded.record.id], status: .discarded)

        let entries = try ProfileSourcesLedger.entries(for: "p1", db: db)
        // Only the KEPT record is in the ledger — discarded is excluded.
        #expect(entries.map(\.id) == ["freebmd_birth_7a_631"])
        let e = entries[0]
        #expect(e.sourceID == "freebmd")
        #expect(e.recordType == .birth)
        #expect(e.citation.contains("7a/631"))
        // It shows WHAT it establishes — same absorptionPlan the write path runs,
        // so the ledger can never claim a fact the apply wouldn't land.
        #expect(e.establishes.contains { $0.contains("birth place Belper") })
        #expect(e.establishes.contains { $0.hasPrefix("birth date") })
    }

    @Test func gedcomOnlyProfileHasNoResearchRecords() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "p2", firstName: "Jane", lastName: "Doe",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        // No research applied → an empty ledger (the view shows an "imported,
        // no research records yet" state). No crash, no fabricated rows.
        #expect(try ProfileSourcesLedger.entries(for: "p2", db: db).isEmpty)
    }
}

// Registration-twin dedup (owner dogfood 2026-07-30): the same GRO entry
// (7b/920) indexed as two FreeBMD rows with DIFFERENT transcriptions showed as
// "1 applied + 1 researched" in the per-fact expander. Twin rows are one real
// record — one card, applied standing wins, removal cleans both.
@MainActor
struct ProfileSourcesLedgerTwinTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func death(_ id: String, given: String, vol: String, page: String) -> ScoredRecord {
        let common = RecordCommon(id: id, sourceID: "freebmd", name: nil,
                                  surname: "KEYWORTH", givenName: given,
                                  detailURL: nil, rawFields: [:])
        let record = SourceRecord.death(DeathRecord(
            common: common, deathYear: 1916, deathDate: nil, deathPlace: nil,
            age: 46, quarter: "Dec", district: "Bakewell", volume: vol, page: page))
        return ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")
    }

    @Test func registrationTwinsCollapseToOneCardWithAppliedStanding() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "p1", firstName: "Elizabeth", lastName: "Shaw",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)

        // Twin rows: same registration, DIFFERENT transcriptions → different
        // citations (the citation-identity fallback can't collapse these).
        let applied = death("freebmd_death_7b_920_137442739", given: "ELIZABETH", vol: "7b", page: "920")
        let twin = death("freebmd_death_7b_920_137435711", given: "ELIZABETH A", vol: "7b", page: "920")
        try db.saveEvidence(profileID: "p1", scored: applied,
                            citationFull: "FreeBMD, Elizabeth Keyworth, Dec 1916, Bakewell, vol. 7b/920; accessed 18 Jul 2026.",
                            citationURL: nil)
        try db.saveEvidence(profileID: "p1", scored: twin,
                            citationFull: "FreeBMD, Elizabeth A Keyworth, Dec 1916, Bakewell, vol. 7b/920; accessed 30 Jul 2026.",
                            citationURL: nil)
        try db.updateEvidenceUserStatus(profileID: "p1", sourceRecordIDs: [applied.record.id], status: .savedAsLead)

        let records = try ProfileSourcesLedger.allRecords(for: "p1", db: db)
        let deaths = records.filter { $0.recordType == .death }
        #expect(deaths.count == 1, "twin rows are one card, got \(deaths.map(\.id))")
        #expect(Set(deaths.first?.duplicateIDs ?? []) ==
                ["freebmd_death_7b_920_137442739", "freebmd_death_7b_920_137435711"],
                "removal must clean both underlying rows")
    }

    @Test func distinctRegistrationsStaySeparateCards() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "p2", firstName: "Elizabeth", lastName: "Shaw",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        try db.saveEvidence(profileID: "p2",
                            scored: death("d1", given: "ELIZABETH", vol: "7b", page: "920"),
                            citationFull: "FreeBMD, Dec 1916, Bakewell, vol. 7b/920", citationURL: nil)
        try db.saveEvidence(profileID: "p2",
                            scored: death("d2", given: "ELIZABETH", vol: "1a", page: "55"),
                            citationFull: "FreeBMD, Dec 1916, Ashby, vol. 1a/55", citationURL: nil)
        let deaths = try ProfileSourcesLedger.allRecords(for: "p2", db: db)
            .filter { $0.recordType == .death }
        #expect(deaths.count == 2, "different registrations must not merge")
    }
}

// Applied vs saved-as-lead (owner dogfood 2026-07-31): "Save as lead" stamps
// the same `.savedAsLead` status the apply path uses, so Mary Ellen
// Thompson's KEPT census rendered a green "Applied" pill while her Birth
// stayed "Not recorded". `.applied` standing now requires the apply ACTION:
// v56 `applied_at`, or (pre-v56 rows — the column has no backfill) the
// apply's citation fingerprint on the profile's field sources.
@MainActor
struct ProfileSourcesLedgerAppliedStandingTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let db = try ProjectDatabase(path: path)
        try db.dbQueue.write { sql in
            try sql.execute(sql: "INSERT INTO project_meta (id, name, source_kind, source_value, created_at) VALUES ('t','T','manual','',?)", arguments: [Date()])
        }
        return db
    }

    private func census(_ id: String) -> ScoredRecord {
        let record = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: id, sourceID: "freecen", name: "Mary THOMPSON",
                                 surname: nil, givenName: nil,
                                 detailURL: "https://freecen/\(id)", rawFields: [:]),
            censusYear: 1891, age: nil, birthYear: 1871,
            birthPlace: "Swadlincote", district: "Church Gresley"))
        return ScoredRecord(id: id, record: record, verdict: .lead, gates: [], summary: "")
    }

    @Test func savedAsLeadAloneIsNotApplied() throws {
        // The Mary specimen: kept via Save as lead, never applied.
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "mary", firstName: "Mary Ellen", lastName: "Thompson",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        try db.saveEvidence(profileID: "mary", scored: census("c1"),
                            citationFull: "FreeCen, Mary THOMPSON, Church Gresley; accessed 30 Jul 2026.",
                            citationURL: "https://freecen/c1")
        try db.updateEvidenceUserStatus(profileID: "mary", sourceRecordIDs: ["c1"], status: .savedAsLead)

        let profile = try #require(try db.loadProfile(id: "mary"))
        let records = try ProfileSourcesLedger.allRecords(for: "mary", db: db, profile: profile)
        #expect(records.first?.standing == .researched,
                "a kept-as-lead record must never read as Applied")
    }

    @Test func v56AppliedStampIsApplied() throws {
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "mary", firstName: "Mary", lastName: "Thompson",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        try db.saveEvidence(profileID: "mary", scored: census("c1"),
                            citationFull: "FreeCen; accessed 30 Jul 2026.", citationURL: "https://freecen/c1")
        try db.updateEvidenceUserStatus(profileID: "mary", sourceRecordIDs: ["c1"], status: .savedAsLead)
        try db.markEvidenceApplied(evidenceID: "mary|c1")

        let profile = try #require(try db.loadProfile(id: "mary"))
        let records = try ProfileSourcesLedger.allRecords(for: "mary", db: db, profile: profile)
        #expect(records.first?.standing == .applied)
    }

    @Test func preV56AppliedRowRecognisedByCitationFingerprint() throws {
        // A row applied BEFORE v56: applied_at is NULL, but the apply left
        // the record's citation on the profile's field sources.
        let db = try makeDB()
        _ = try db.addProfile(Profile(
            id: "mary", firstName: "Mary", lastName: "Thompson",
            gender: .female, isDeleted: false, sources: [:], disputes: [:]), source: .gedcom)
        try db.saveEvidence(profileID: "mary", scored: census("c1"),
                            citationFull: "FreeCen; accessed 30 Jul 2026.", citationURL: "https://freecen/c1")
        try db.updateEvidenceUserStatus(profileID: "mary", sourceRecordIDs: ["c1"], status: .savedAsLead)
        var profile = try #require(try db.loadProfile(id: "mary"))
        profile.sources[.birthLocation] = [FieldSource(
            origin: .freecen, raw: "Swadlincote", addedAt: Date(),
            citation: Citation(title: "Census 1891", url: "https://freecen/c1",
                               dateAccessed: Date(), notes: "FreeCen; accessed 18 Jul 2026."))]

        let records = try ProfileSourcesLedger.allRecords(for: "mary", db: db, profile: profile)
        #expect(records.first?.standing == .applied,
                "legacy applied rows keep their Applied standing via the citation fingerprint")
    }
}

// Cross-anchor consistency lines (owner request 2026-07-31): each candidate
// row states the arithmetic against the profile's OTHER facts — "If theirs:
// married at 30 (1915); Reginald born when they were 31" — with graded
// prefixes for strained (Unlikely) and contradictory (Impossible) fits.
// Fixtures mirror Mary Ellen Thompson (m.1915, Reginald b.1916, no birth).
@MainActor
struct CrossAnchorNoteTests {

    private let maryAnchors = ProfileSourcesLedger.LifeAnchors(
        marriageYears: [1915],
        earliestChildBirthYear: 1916, latestChildBirthYear: 1916,
        childName: "Reginald Holmes", deathYear: nil, birthYear: nil)

    private func birth(_ year: Int) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: "b\(year)", sourceID: "freebmd", name: nil,
                                 surname: "THOMPSON", givenName: "MARY",
                                 detailURL: nil, rawFields: [:]),
            birthYear: year, birthDate: nil, birthPlace: nil,
            quarter: "Mar", district: "Belper", volume: "7b", page: "1",
            mothersMaidenName: nil))
    }

    private func death(_ year: Int) -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(id: "d\(year)", sourceID: "freebmd", name: nil,
                                 surname: "THOMPSON", givenName: "MARY",
                                 detailURL: nil, rawFields: [:]),
            deathYear: year, deathDate: nil, deathPlace: nil, age: nil,
            quarter: "Mar", district: "Belper", volume: "7b", page: "2"))
    }

    @Test func plausibleBirthStatesTheArithmetic() {
        let note = ProfileSourcesLedger.crossAnchorNote(birth(1885), anchors: maryAnchors)
        #expect(note == "If theirs: married at 30 (1915); Reginald Holmes born when they were 31.")
    }

    @Test func strainedBirthReadsUnlikely() {
        // b.1901 → married at 14, mother at 15: arithmetically possible,
        // historically strained — flagged, never silently plausible.
        let note = ProfileSourcesLedger.crossAnchorNote(birth(1901), anchors: maryAnchors)
        #expect(note?.hasPrefix("Unlikely if theirs:") == true)
        #expect(note?.contains("married at 14") == true)
    }

    @Test func birthAfterMarriageIsImpossible() {
        let note = ProfileSourcesLedger.crossAnchorNote(birth(1920), anchors: maryAnchors)
        #expect(note?.hasPrefix("Impossible if theirs:") == true)
        #expect(note?.contains("born after the 1915 marriage") == true)
    }

    @Test func deathBeforeChildBirthIsImpossible() {
        // The namesake-killer for her 565 death candidates: died 1898,
        // before Reginald's 1916 birth.
        let note = ProfileSourcesLedger.crossAnchorNote(death(1898), anchors: maryAnchors)
        #expect(note?.hasPrefix("Impossible if theirs:") == true)
        #expect(note?.contains("died before Reginald Holmes's 1916 birth") == true)
    }

    @Test func consistentDeathStatesTheAlignment() {
        let note = ProfileSourcesLedger.crossAnchorNote(death(1960), anchors: maryAnchors)
        #expect(note == "If theirs: alive for Reginald Holmes's 1916 birth.")
    }

    @Test func noAnchorsMeansNoNote() {
        let empty = ProfileSourcesLedger.LifeAnchors()
        #expect(ProfileSourcesLedger.crossAnchorNote(birth(1885), anchors: empty) == nil)
        #expect(ProfileSourcesLedger.crossAnchorNote(death(1898), anchors: empty) == nil)
    }

    @Test func censusImpliedYearGetsTheSameTreatment() {
        let census = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "c1", sourceID: "freecen", name: "Mary THOMPSON",
                                 surname: nil, givenName: nil, detailURL: nil, rawFields: [:]),
            censusYear: 1891, age: nil, birthYear: 1871,
            birthPlace: "Swadlincote", district: "Church Gresley"))
        let note = ProfileSourcesLedger.crossAnchorNote(census, anchors: maryAnchors)
        #expect(note == "If theirs: married at 44 (1915); Reginald Holmes born when they were 45.")
    }
}
