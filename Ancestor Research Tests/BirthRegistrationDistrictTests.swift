import Testing
import Foundation
import GRDB
import AncestorKit
@testable import Ancestor_Research

/// LOCATION_MODEL_SPEC Part II, Slice C — `Profile.birthRegistrationDistrict` is a
/// first-class, structured GRO registration-district id ("DBY:Ashbourne-RD"),
/// derived metadata populated by BMD-birth apply (no FieldSource; provenance is
/// the birth citation). Distinct from `birthLocation` (the *place*), which is
/// never touched. Regression driver: Abraham keeps `Alport`/`Hognaston` and gains
/// the district; sibling-by-RD clustering can then key on it.
@MainActor
struct BirthRegistrationDistrictTests {

    private func makeDB() throws -> ProjectDatabase {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try ProjectDatabase(path: path)
    }

    // MARK: - Model

    @Test func codableRoundTripsBirthRegistrationDistrict() throws {
        let p = Profile(id: "p", firstName: "Abraham", lastName: "Twyford", gender: .male,
                        birthLocation: "Alport, Derbyshire (DBY)",
                        birthRegistrationDistrict: "DBY:Bakewell-RD",
                        isDeleted: false, sources: [:], disputes: [:])
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(back.birthRegistrationDistrict == "DBY:Bakewell-RD")
        // The place string is a separate field and must round-trip independently.
        #expect(back.birthLocation == "Alport, Derbyshire (DBY)")
    }

    /// Back-compat: a Profile blob serialised before Slice C carries no
    /// `birthRegistrationDistrict` key and must decode to nil, not throw. (Keys
    /// like `sources` are omitted — they default to empty; a Profile's enum-keyed
    /// dictionaries encode as arrays, not objects, so this stays a realistic old
    /// blob without hand-forging their wire shape.)
    @Test func preSliceCBlobDecodesToNil() throws {
        let json = #"{"id":"p","firstName":"Abraham","lastName":"Twyford","birthLocation":"Alport, Derbyshire (DBY)","isDeleted":false}"#
        let back = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        #expect(back.birthRegistrationDistrict == nil)
        #expect(back.birthLocation == "Alport, Derbyshire (DBY)")
    }

    // MARK: - Persistence

    @Test func dbPersistsBirthRegistrationDistrict() throws {
        let db = try makeDB()
        let p = Profile(id: "p", firstName: "A", lastName: "B", gender: .male,
                        birthRegistrationDistrict: "DBY:Bakewell-RD",
                        isDeleted: false, sources: [:], disputes: [:])
        _ = try db.addProfile(p, source: .gedcom)
        #expect(try db.loadProfile(id: "p")?.birthRegistrationDistrict == "DBY:Bakewell-RD")
    }

    /// `setBirthRegistrationDistrictIfEmpty` fills an empty column but never
    /// clobbers an existing RD — a user-set or earlier-resolved value wins, and
    /// re-applying the same record is a no-op.
    @Test func setIsCheckBeforeOverwrite() throws {
        let db = try makeDB()
        _ = try db.addProfile(
            Profile(id: "p", firstName: "A", lastName: "B", gender: .male,
                    isDeleted: false, sources: [:], disputes: [:]),
            source: .gedcom)
        try db.setBirthRegistrationDistrictIfEmpty(profileID: "p", district: "DBY:Ashbourne-RD")
        #expect(try db.loadProfile(id: "p")?.birthRegistrationDistrict == "DBY:Ashbourne-RD")
        // A later derived guess must NOT overwrite the settled value.
        try db.setBirthRegistrationDistrictIfEmpty(profileID: "p", district: "DBY:Bakewell-RD")
        #expect(try db.loadProfile(id: "p")?.birthRegistrationDistrict == "DBY:Ashbourne-RD")
    }

    // MARK: - Resolver

    /// FreeBMD indexes the district as "Ashborne" (no 'u'); it must resolve to
    /// the same RD id as the catalogue's canonical "Ashbourne", or apply misses.
    @Test func resolverToleratesAshborneSpelling() {
        let variant = RegistrationDistrictResolver.districtID(forPlaceOrDistrict: "Ashborne", chapman: "DBY", year: 1885)
        let canonical = RegistrationDistrictResolver.districtID(forPlaceOrDistrict: "Ashbourne", chapman: "DBY", year: 1885)
        #expect(variant != nil)
        #expect(variant == canonical)
    }

    /// Chapman anchor is read from the stored "(DBY)" display suffix (the
    /// parallel-safe path B(i) settled on).
    @Test func chapmanReadsDisplaySuffix() {
        let p = Profile(id: "p", gender: .male, birthLocation: "Hognaston, Derbyshire (DBY)",
                        isDeleted: false, sources: [:], disputes: [:])
        #expect(RegistrationDistrictResolver.chapman(forProfile: p) == "DBY")
    }

    // MARK: - Apply integration

    /// Applying a BMD birth record populates the RD from the record's `district`
    /// while leaving the birthplace string untouched (Abraham keeps his place,
    /// gains his registration district).
    @Test func applyPopulatesBirthRegistrationDistrict() throws {
        let db = try makeDB()
        let profile = Profile(id: "ab", externalIDs: [:], firstName: "Abraham", lastName: "Twyford",
                              gender: .male, attributes: nil, birthDate: nil,
                              birthLocation: "Hognaston, Derbyshire (DBY)",
                              deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
                              sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()
        let record = SourceRecord.birth(BirthRecord(
            common: RecordCommon(id: "b1", sourceID: "freebmd", name: "Abraham Twyford",
                                 surname: "Twyford", givenName: "Abraham", rawFields: [:]),
            birthYear: 1885, birthDate: nil, birthPlace: nil, quarter: "Dec",
            district: "Ashborne", volume: "7b", page: "662", mothersMaidenName: nil))
        let scored = ScoredRecord(id: "b1", record: record, verdict: .fact, gates: [], summary: "")

        _ = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)

        let after = try #require(try db.loadProfile(id: "ab"))
        let expected = RegistrationDistrictResolver.districtID(
            forPlaceOrDistrict: "Ashborne", chapman: "DBY", year: 1885)
        #expect(expected != nil, "precondition: Ashborne must resolve in DBY")
        #expect(after.birthRegistrationDistrict == expected)
        #expect(after.birthLocation == "Hognaston, Derbyshire (DBY)", "the place string is untouched")
    }

    /// Only a BIRTH record's district is a birth registration district — a death
    /// record's `district` (where the person died) must not populate it.
    @Test func deathRecordDoesNotPopulateBirthRD() throws {
        let db = try makeDB()
        let profile = Profile(id: "d", externalIDs: [:], firstName: "A", lastName: "B",
                              gender: .male, attributes: nil, birthDate: nil,
                              birthLocation: "Hognaston, Derbyshire (DBY)",
                              deathDate: nil, deathLocation: nil, bio: nil, isDeleted: false,
                              sources: [:], disputes: [:])
        _ = try db.addProfile(profile, source: .gedcom)
        let snapshot = try db.buildSnapshot()
        let record = SourceRecord.death(DeathRecord(
            common: RecordCommon(id: "dd", sourceID: "freebmd", name: "A B",
                                 surname: "B", givenName: "A", rawFields: [:]),
            deathYear: 1950, deathDate: nil, deathPlace: "Ashbourne", age: 65,
            quarter: "Dec", district: "Ashborne", volume: "7b", page: "1", spouseSurname: nil))
        let scored = ScoredRecord(id: "dd", record: record, verdict: .fact, gates: [], summary: "")

        _ = ApplyEngine.applyFactToSubject(scored, profile: profile, snapshot: snapshot, db: db)
        #expect(try db.loadProfile(id: "d")?.birthRegistrationDistrict == nil)
    }
}
