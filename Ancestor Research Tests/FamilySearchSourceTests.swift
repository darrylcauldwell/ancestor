import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the strictness contract for FamilySearchSource — the `~` exact-match
/// modifier per spec §4.3 and the client-side surname guard in the parser.
struct FamilySearchSourceTests {

    private func query(strictness: SearchStrictness, surname: String = "Cauldwell") -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: "Ernest",
            recordType: .death,
            yearFrom: 1919, yearTo: 2017,
            gender: .male, region: nil,
            sourceParams: .generic,
            strictness: strictness
        )
    }

    // MARK: - URL construction

    @Test func strictAppendsTildeToSurname() {
        let url = FamilySearchSource.buildSearchURL(query: query(strictness: .strict), surname: "Cauldwell")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let surnameItem = items.first(where: { $0.name == "q.surname" })?.value
        #expect(surnameItem == "Cauldwell~")
    }

    @Test func looseSendsBareSurname() {
        let url = FamilySearchSource.buildSearchURL(query: query(strictness: .loose), surname: "Cauldwell")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let surnameItem = items.first(where: { $0.name == "q.surname" })?.value
        #expect(surnameItem == "Cauldwell")
    }

    @Test func variantSendsBareSurname() {
        // .variant is fanned out by the dispatcher — each request carries the
        // already-substituted surname and we still let the server phonetically
        // widen, with the parser guarding exact match per the substituted form.
        let url = FamilySearchSource.buildSearchURL(query: query(strictness: .variant, surname: "Caldwell"), surname: "Caldwell")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let surnameItem = items.first(where: { $0.name == "q.surname" })?.value
        #expect(surnameItem == "Caldwell")
    }

    // MARK: - Family-context axes (spec §23)

    @Test func emitsAllFamilyContextAxesWhenPopulated() {
        // When all axes are populated, every corresponding q.* param
        // appears in the URL. Single test covers the eight new
        // parameters — emission is mechanical per-axis so one positive
        // case + one negative is enough to pin the contract.
        let q = RecordQuery(
            surname: "Cauldwell", givenName: "Ernest",
            recordType: .death,
            yearFrom: nil, yearTo: nil,
            gender: .male, region: nil,
            sourceParams: .generic,
            strictness: .strict,
            birthPlace: "Loscoe, Derbyshire",
            deathPlace: "Chesterfield, Derbyshire",
            spouseSurname: "Wheeldon",
            spouseGivenName: "Kathleen",
            fatherSurname: "Cauldwell",
            fatherGivenName: "George",
            motherSurname: "Ward",
            motherGivenName: "Mary"
        )
        let url = FamilySearchSource.buildSearchURL(query: q, surname: "Cauldwell")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(byName["q.birthLikePlace"] == "Loscoe, Derbyshire")
        #expect(byName["q.deathLikePlace"] == "Chesterfield, Derbyshire")
        #expect(byName["q.spouseSurname"] == "Wheeldon")
        #expect(byName["q.spouseGivenName"] == "Kathleen")
        #expect(byName["q.fatherSurname"] == "Cauldwell")
        #expect(byName["q.fatherGivenName"] == "George")
        #expect(byName["q.motherSurname"] == "Ward")
        #expect(byName["q.motherGivenName"] == "Mary")
    }

    @Test func familyContextAxesOmittedWhenNil() {
        // When axes are nil (the default for any subject without a
        // populated FamilyContext / linked relatives / known locations),
        // the q.* params don't appear at all. Avoids emitting empty
        // q.spouseSurname= that the server might interpret as
        // "search for records with no spouse".
        let q = RecordQuery(
            surname: "Cauldwell", givenName: "Ernest",
            recordType: .death,
            yearFrom: nil, yearTo: nil,
            gender: .male, region: nil,
            sourceParams: .generic,
            strictness: .strict
        )
        let url = FamilySearchSource.buildSearchURL(query: q, surname: "Cauldwell")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let names = Set(items.map(\.name))
        #expect(!names.contains("q.birthLikePlace"))
        #expect(!names.contains("q.deathLikePlace"))
        #expect(!names.contains("q.spouseSurname"))
        #expect(!names.contains("q.spouseGivenName"))
        #expect(!names.contains("q.fatherSurname"))
        #expect(!names.contains("q.fatherGivenName"))
        #expect(!names.contains("q.motherSurname"))
        #expect(!names.contains("q.motherGivenName"))
    }

    @Test func givenNameStaysPhonetic() {
        // Given names keep server-side phonetics on at every strictness so
        // Ernest can still match Ernie etc. Only surname gets the `~`.
        let url = FamilySearchSource.buildSearchURL(query: query(strictness: .strict), surname: "Cauldwell")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let givenItem = items.first(where: { $0.name == "q.givenName" })?.value
        #expect(givenItem == "Ernest")
    }

    // MARK: - Parser surname guard

    private func envelope(personas: [(surname: String, given: String)]) -> Data {
        // Minimal GEDCOMx envelope — one entry with N personas. Each persona
        // has a structured Surname part so the parser's exact-match guard
        // exercises the structured path, not the fullText fallback.
        let personJSONs = personas.enumerated().map { i, p in
            """
            {
              "id": "p\(i)",
              "names": [{
                "nameForms": [{
                  "fullText": "\(p.given) \(p.surname)",
                  "parts": [
                    {"type": "http://gedcomx.org/Given", "value": "\(p.given)"},
                    {"type": "http://gedcomx.org/Surname", "value": "\(p.surname)"}
                  ]
                }]
              }],
              "facts": [{
                "type": "http://gedcomx.org/Death",
                "date": {"original": "1980", "formal": "+1980"}
              }]
            }
            """
        }.joined(separator: ",")
        let json = """
        {
          "entries": [{
            "content": {
              "gedcomx": {
                "persons": [\(personJSONs)],
                "sourceDescriptions": [{
                  "about": "ark:/61903/coll-1",
                  "titles": [{"value": "Test Collection"}]
                }]
              }
            }
          }]
        }
        """
        return Data(json.utf8)
    }

    @Test func strictDropsWrongSurnamePersonas() throws {
        let data = envelope(personas: [
            (surname: "Cauldwell", given: "Ernest"),
            (surname: "Colwell",   given: "Ernest"),
            (surname: "Caldwell",  given: "Ernest"),
            (surname: "Owens",     given: "Ernest"),
        ])
        let records = try FamilySearchSource.parseSearchResponse(data: data, query: query(strictness: .strict))
        let surnames = records.compactMap { $0.common.surname }
        #expect(records.count == 1)
        #expect(surnames == ["Cauldwell"])
    }

    @Test func looseAcceptsRegisteredVariantsRejectsOthers() throws {
        // Cauldwell variants per surname-variants.json: caldwell, caudwell,
        // coldwell, coudwell. Colwell (no D) is NOT a registered variant and
        // is the kind of phonetic widening we want to drop client-side.
        let data = envelope(personas: [
            (surname: "Cauldwell", given: "Ernest"),  // canonical — keep
            (surname: "Caldwell",  given: "Ernest"),  // registered variant — keep
            (surname: "Coldwell",  given: "Ernest"),  // registered variant — keep
            (surname: "Colwell",   given: "Ernest"),  // not registered — drop
            (surname: "Owens",     given: "Ernest"),  // not registered — drop
        ])
        let records = try FamilySearchSource.parseSearchResponse(data: data, query: query(strictness: .loose))
        let surnames = Set(records.compactMap { $0.common.surname })
        #expect(surnames == Set(["Cauldwell", "Caldwell", "Coldwell"]))
    }

    @Test func looseFallsBackToCanonicalOnlyForUnknownSurname() throws {
        // A surname with no entry in surname-variants.json should only accept
        // the canonical form at .loose — no widening at all.
        let data = envelope(personas: [
            (surname: "Tickle",     given: "Ernest"),
            (surname: "TickleSmith", given: "Ernest"),
        ])
        let records = try FamilySearchSource.parseSearchResponse(data: data, query: query(strictness: .loose, surname: "Tickle"))
        let surnames = Set(records.compactMap { $0.common.surname })
        #expect(surnames == Set(["Tickle"]))
    }

    @Test func variantGuardsOnFannedOutSurname() throws {
        // .variant: dispatcher has substituted the variant into query.surname.
        // Parser should accept the substituted form only.
        let data = envelope(personas: [
            (surname: "Cauldwell", given: "Ernest"),
            (surname: "Caldwell",  given: "Ernest"),
        ])
        let q = query(strictness: .variant, surname: "Caldwell")
        let records = try FamilySearchSource.parseSearchResponse(data: data, query: q)
        let surnames = records.compactMap { $0.common.surname }
        #expect(surnames == ["Caldwell"])
    }

    // MARK: - FAG memorial-id extraction (spec §22 bridge anchor)

    @Test func extractsMemorialIdFromFindAGraveCollection() {
        let raw = ["field.ExtRecordId.original": "304726395949"]
        let id = FamilySearchSource.extractFindAGraveMemorialID(
            collectionTitle: "Find A Grave Index",
            rawFields: raw
        )
        #expect(id == 304726395949)
    }

    @Test func extractsMemorialIdFromInterpretedField() {
        let raw = ["field.ExtRecordId.interpreted": "12345"]
        let id = FamilySearchSource.extractFindAGraveMemorialID(
            collectionTitle: "Find a Grave, database and images",
            rawFields: raw
        )
        #expect(id == 12345)
    }

    @Test func returnsNilForNonFindAGraveCollection() {
        let raw = ["field.ExtRecordId.original": "12345"]
        let id = FamilySearchSource.extractFindAGraveMemorialID(
            collectionTitle: "England Civil Registration Death Index",
            rawFields: raw
        )
        #expect(id == nil)
    }

    @Test func returnsNilWhenExtRecordIdAbsent() {
        let id = FamilySearchSource.extractFindAGraveMemorialID(
            collectionTitle: "Find A Grave Index",
            rawFields: [:]
        )
        #expect(id == nil)
    }

    @Test func returnsNilOnFagCollectionWhenOnlyPersonaIdAvailable() {
        // FS persona ids ("p_<12-digit-number>") are FS-internal identifiers
        // with no relationship to FAG memorial numbering. Verified manually
        // against Ernest Cauldwell — FS persona p_304726395949 vs real FAG
        // memorial 271612558. An earlier speculative fallback that stripped
        // "p_" and used the rest as a memorial id always 404'd; this test
        // pins that the fallback is GONE — when only personaID is available
        // (no ExtRecordId), the extractor returns nil so the bridge doesn't
        // fire on bogus targets.
        let raw = ["personaID": "p_304726395949"]
        let id = FamilySearchSource.extractFindAGraveMemorialID(
            collectionTitle: "Find A Grave Index",
            rawFields: raw
        )
        #expect(id == nil)
    }

    @Test func stripsNonDigitPrefixFromMemorialId() {
        let raw = ["field.ExtRecordId.original": "memorial-12345"]
        let id = FamilySearchSource.extractFindAGraveMemorialID(
            collectionTitle: "Find A Grave Index",
            rawFields: raw
        )
        #expect(id == 12345)
    }

    @Test func strictGuardIsCaseInsensitive() throws {
        let data = envelope(personas: [
            (surname: "CAULDWELL", given: "Ernest"),
            (surname: "Cauldwell", given: "Ernest"),
        ])
        let records = try FamilySearchSource.parseSearchResponse(data: data, query: query(strictness: .strict))
        #expect(records.count == 2)
    }
}
