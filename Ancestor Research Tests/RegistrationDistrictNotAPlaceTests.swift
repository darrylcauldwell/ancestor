import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// EV30 (owner dogfood 2026-08-26) — a GRO **registration district** is not a
/// place of birth or death, and must never land in `birthLocation` /
/// `deathLocation`.
///
/// Whittington children register at Chesterfield; the BMD index names the
/// district, never the town. EV4 stopped a district OVERWRITING a parish-level
/// birthplace, but its guard sits behind `shouldOverwriteStringField`'s
/// empty-field early return, so the BLANK-FILL case survived — and blank-fill
/// is the damaging one. Once a `.researchSource` district is seated, no other
/// research source can displace it (tier equality), so the true parish is
/// locked out permanently and a later census birthplace opens a dispute
/// instead of landing.
///
/// Nothing is lost: for births the district lands structured and uncited in
/// `Profile.birthRegistrationDistrict`, and for both types it survives in the
/// citation and the evidence row's `record_json`.
@MainActor
struct RegistrationDistrictNotAPlaceTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    private func stringFields(_ plan: [Absorption]) -> [ProfileField] {
        plan.compactMap { if case .stringField(let f, _) = $0 { f } else { nil } }
    }
    private func dateFields(_ plan: [Absorption]) -> [ProfileField] {
        plan.compactMap { if case .dateField(let f, _) = $0 { f } else { nil } }
    }
    private func stringValue(_ plan: [Absorption], _ field: ProfileField) -> String? {
        plan.compactMap { if case .stringField(let f, let v) = $0, f == field { v } else { nil } }.first
    }

    /// Emma Gladwin's own registration: FreeBMD carries a district and no
    /// place, which is the ONLY shape FreeBMD ever produces.
    private func districtOnlyBirth(district: String = "Chesterfield", year: Int = 1885) -> SourceRecord {
        .birth(BirthRecord(
            common: RecordCommon(id: "b1", sourceID: "freebmd", surname: "Gladwin",
                                 givenName: "Emma", rawFields: [:]),
            birthYear: year, birthDate: nil, birthPlace: nil,
            quarter: "Dec", district: district, volume: "7b", page: "513",
            mothersMaidenName: "Hewkin"))
    }

    private func districtOnlyDeath(district: String = "Chesterfield") -> SourceRecord {
        .death(DeathRecord(
            common: RecordCommon(id: "d1", sourceID: "freebmd", surname: "Gladwin",
                                 givenName: "Emma", rawFields: [:]),
            deathYear: 1951, deathDate: nil, deathPlace: nil, age: 66,
            quarter: "Dec", district: district, volume: "7b", page: "44"))
    }

    private func subject() -> Profile {
        Profile(id: "em", externalIDs: [:], firstName: "Emma", middleName: nil,
                lastName: "Gladwin", gender: .female, attributes: nil,
                birthDate: nil, birthLocation: nil, deathDate: nil, deathLocation: nil,
                bio: nil, isDeleted: false, sources: [:], disputes: [:])
    }

    // MARK: - The plan

    @Test func birthIndexWithOnlyADistrictEmitsNoBirthPlace() {
        let plan = districtOnlyBirth().absorptionPlan(profileID: "em")
        #expect(dateFields(plan) == [.birthDate], "the date still lands — only the place is refused")
        #expect(!stringFields(plan).contains(.birthLocation),
                "Chesterfield is where the birth was REGISTERED, not where it happened")
    }

    @Test func deathIndexWithOnlyADistrictEmitsNoDeathPlace() {
        let plan = districtOnlyDeath().absorptionPlan(profileID: "em")
        // (`.birthDate` rides along too — the age-implied corroboration tail.)
        #expect(dateFields(plan).contains(.deathDate), "the date still lands")
        #expect(!stringFields(plan).contains(.deathLocation))
    }

    /// The other half of the rule: a record that genuinely NAMES a place still
    /// absorbs it. FamilySearch personas carry a real `birthPlace` and no
    /// district, and that half of the old expression was always legitimate.
    @Test func aRecordThatReallyNamesAPlaceStillEmitsIt() {
        let plan = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "fs", sourceID: "familysearch", rawFields: [:]),
            birthYear: 1885, birthDate: nil, birthPlace: "Whittington, Derbyshire"))
            .absorptionPlan(profileID: "em")
        #expect(stringFields(plan) == [.birthLocation])
        #expect(stringValue(plan, .birthLocation) == "Whittington, Derbyshire")
    }

    // MARK: - Through the real apply path

    /// The blank-fill regression EV4's overwrite guard could not reach.
    @Test func applyingABMDBirthLeavesAnEmptyBirthplaceEmptyAndFillsTheRD() throws {
        let db = try makeDB()
        let profile = subject()
        _ = try db.addProfile(profile, source: .gedcom)
        let record = districtOnlyBirth()
        let scored = ScoredRecord(id: record.id, record: record, verdict: .fact, gates: [], summary: "")

        _ = ApplyEngine.applyFactToSubject(
            scored, profile: profile, snapshot: try db.buildSnapshot(), db: db)

        let after = try #require(try db.loadProfile(id: "em"))
        #expect(after.birthLocation == nil, "a registration district is not a birthplace")
        #expect(after.birthDate != nil, "the record still landed — this is not an inert apply")
        // The district is not dropped, it is ROUTED: structured, uncited, and
        // in the one field that documents itself as a registration district.
        let expected = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Chesterfield",
            chapman: RegistrationDistrictResolver.chapman(forProfile: profile),
            year: 1885)
        #expect(expected != nil, "precondition: Chesterfield must resolve as an RD")
        #expect(after.birthRegistrationDistrict == expected)
    }

    /// WHY it matters. The apply-path tier maps every research source to
    /// `.researchSource`, and `shouldOverwriteStringField` needs a STRICTLY
    /// higher tier — so a district seated in `birthLocation` could never be
    /// displaced by the census that actually names the parish, and the two
    /// were not a refinement pair either, so the census opened a permanent
    /// dispute instead. Fails at HEAD; passes with the district refused.
    @Test func aLaterCensusBirthplaceIsNoLongerLockedOutByTheDistrict() throws {
        let db = try makeDB()
        _ = try db.addProfile(subject(), source: .gedcom)

        let bmd = districtOnlyBirth()
        let beforeBMD = try #require(try db.loadProfile(id: "em"))
        _ = ApplyEngine.applyFactToSubject(
            ScoredRecord(id: bmd.id, record: bmd, verdict: .fact, gates: [], summary: ""),
            profile: beforeBMD, snapshot: try db.buildSnapshot(), db: db)

        let census = SourceRecord.census(CensusRecord(
            common: RecordCommon(id: "c1", sourceID: "freecen", rawFields: [:]),
            censusYear: 1891, age: 6, birthYear: 1885,
            birthPlace: "Whittington", birthCounty: "Derbyshire"))
        let beforeCensus = try #require(try db.loadProfile(id: "em"))
        _ = ApplyEngine.applyFactToSubject(
            ScoredRecord(id: census.id, record: census, verdict: .fact, gates: [], summary: ""),
            profile: beforeCensus, snapshot: try db.buildSnapshot(), db: db)

        #expect(try db.loadProfile(id: "em")?.birthLocation == "Whittington, Derbyshire",
                "the parish must be free to land — the district was never her birthplace")
        #expect(try db.openDisputes(profileID: "em").filter { $0.field == "birthLocation" }.isEmpty,
                "no dispute between a district and the parish inside it")
    }

    // MARK: - Legacy data stays removable

    /// Removal derives its targets by re-walking `absorptionPlan`, so dropping
    /// the emission without a compatibility shim would strand every district
    /// an earlier build already wrote — the record's Remove button would
    /// silently stop reverting it. Candidates are matched against real
    /// `field_sources` rows, so on new data these keys are simply inert.
    @Test func aLegacyDistrictBirthplaceIsStillRemovable() {
        let birthKeys = ProjectDatabase.removalTargetKeys(for: districtOnlyBirth(), profileID: "em")
        #expect(birthKeys.contains("birthLocation|Chesterfield"))
        let deathKeys = ProjectDatabase.removalTargetKeys(for: districtOnlyDeath(), profileID: "em")
        #expect(deathKeys.contains("deathLocation|Chesterfield"))
    }
}
