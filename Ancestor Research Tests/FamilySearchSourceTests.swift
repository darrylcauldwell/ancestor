import Testing
import Foundation
@testable import Ancestor_Research

/// Pins the strictness contract for FamilySearchSource — the `~` exact-match
/// modifier per spec §4.3 and the client-side surname guard in the parser.
struct FamilySearchSourceTests {

    private func query(strictness: SearchStrictness, surname: String = "Cauldwell",
                       recordType: RecordType = .death) -> RecordQuery {
        RecordQuery(
            surname: surname, givenName: "Ernest",
            recordType: recordType,
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
            residencePlace: "Belper, Derbyshire",
            marriagePlace: "Belper, Derbyshire",
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
        #expect(byName["q.residenceLikePlace"] == "Belper, Derbyshire")
        #expect(byName["q.marriageLikePlace"] == "Belper, Derbyshire")
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
        #expect(!names.contains("q.residenceLikePlace"))
        #expect(!names.contains("q.marriageLikePlace"))
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

    // MARK: - Fact-type mapping (Funeral Notices gap + Change 1/2 expansion)

    private func envelope(
        factType: String, date: String,
        collection: String = "United Kingdom, Funeral Notices, 1914-2023",
        extRecordID: String? = nil
    ) -> Data {
        let fieldsJSON = extRecordID.map {
            """
            ,"fields": [{
              "type": "http://gedcomx.org/ExtRecordId",
              "values": [{"type": "http://gedcomx.org/Original", "text": "\($0)"}]
            }]
            """
        } ?? ""
        let json = """
        {
          "entries": [{
            "content": {
              "gedcomx": {
                "persons": [{
                  "id": "p0",
                  "names": [{
                    "nameForms": [{
                      "fullText": "Kenneth Howard Cauldwell",
                      "parts": [
                        {"type": "http://gedcomx.org/Given", "value": "Kenneth Howard"},
                        {"type": "http://gedcomx.org/Surname", "value": "Cauldwell"}
                      ]
                    }]
                  }],
                  "facts": [{
                    "type": "\(factType)",
                    "date": {"original": "\(date)", "formal": "+\(date)"},
                    "place": {"original": "Derbyshire, England"}
                  }]\(fieldsJSON)
                }],
                "sourceDescriptions": [{
                  "about": "ark:/61903/coll-fixture",
                  "titles": [{"value": "\(collection)"}]
                }]
              }
            }
          }]
        }
        """
        return Data(json.utf8)
    }

    @Test func funeralFactTypeMapsToDeathRecordNotParish() throws {
        // The live gap: FamilySearch's "United Kingdom, Funeral Notices"
        // collection uses a "Funeral" fact type, which isn't Death or
        // DeathRegistration. Before the fix this fell through to the
        // `.parish` catch-all and dropped out of death-date scoring
        // entirely — reproducing the Kenneth Howard Cauldwell record
        // that never surfaced in a real run.
        let data = envelope(factType: "http://gedcomx.org/Funeral", date: "2007")
        let records = try FamilySearchSource.parseSearchResponse(data: data, query: query(strictness: .strict))
        #expect(records.count == 1)
        guard case .death(let r) = records.first else {
            Issue.record("Expected .death, got \(String(describing: records.first))")
            return
        }
        #expect(r.deathYear == 2007)
    }

    @Test func unrecognizedFactTypeFallsBackToQueryRecordTypeNotParish() throws {
        // General form of the fix: ANY fact type FamilySearch hasn't
        // explicitly modelled should fall back to the query's own record
        // type (the axis the dispatcher already established), not a
        // hardcoded `.parish` that silently reclassifies the record.
        let data = envelope(factType: "http://gedcomx.org/SomeFutureFactType", date: "1999")
        let records = try FamilySearchSource.parseSearchResponse(data: data, query: query(strictness: .strict))
        #expect(records.count == 1)
        guard case .death(let r) = records.first else {
            Issue.record("Expected .death fallback, got \(String(describing: records.first))")
            return
        }
        #expect(r.deathYear == 1999)
    }

    // MARK: - Change 1: expanded fact-type map (FAMILYSEARCH_READ_LEG_PLAN)

    @Test func birthNoticeFactMapsToBirthRecord() throws {
        let data = envelope(factType: "http://gedcomx.org/BirthNotice", date: "1901")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict, recordType: .birth))
        guard case .birth(let r) = records.first else {
            Issue.record("Expected .birth, got \(String(describing: records.first))")
            return
        }
        #expect(r.birthYear == 1901)
    }

    @Test func blessingFactMapsToBaptismShapedParishRecord() throws {
        // Blessing (LDS, weeks after birth) joins the baptism bucket; the
        // builder emits baptism-typed records as ParishRecord with
        // eventType "baptism" so convergence/writeback treat them as
        // birth-shaped evidence.
        let data = envelope(factType: "http://gedcomx.org/Blessing", date: "1880")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict, recordType: .baptism))
        guard case .parish(let r) = records.first else {
            Issue.record("Expected .parish (baptism-shaped), got \(String(describing: records.first))")
            return
        }
        #expect(r.eventType == "baptism")
        #expect(r.eventYear == 1880)
    }

    @Test func marriageLicenseFactMapsToMarriageRecord() throws {
        let data = envelope(factType: "http://gedcomx.org/MarriageLicense", date: "1912")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict, recordType: .marriage))
        guard case .marriage(let r) = records.first else {
            Issue.record("Expected .marriage, got \(String(describing: records.first))")
            return
        }
        #expect(r.marriageYear == 1912)
    }

    @Test func divorceFactFallsBackToHintAndStampsUnmappedMarker() throws {
        // Decision log: the divorce family never maps to .marriage (a
        // divorce year must not become marriage evidence). It falls back
        // to the query hint AND stamps rawFields["unmappedFactType"] so
        // second-cut enum decisions are data-driven.
        let data = envelope(factType: "http://gedcomx.org/Divorce", date: "1930")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict, recordType: .death))
        guard case .death(let r) = records.first else {
            Issue.record("Expected .death hint fallback, got \(String(describing: records.first))")
            return
        }
        #expect(r.common.rawFields["unmappedFactType"] == "Divorce")
    }

    @Test func mappedFactTypeDoesNotStampUnmappedMarker() throws {
        let data = envelope(factType: "http://gedcomx.org/Funeral", date: "2007")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict))
        #expect(records.first?.common.rawFields["unmappedFactType"] == nil)
    }

    // MARK: - Change 2: burial/cremation dates with FAG carve-out

    @Test func datedBurialRecordCarriesDeathYear() throws {
        let data = envelope(
            factType: "http://gedcomx.org/Burial", date: "1901",
            collection: "England Deaths and Burials, 1538-1991")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict, recordType: .burial))
        guard case .burial(let r) = records.first else {
            Issue.record("Expected .burial, got \(String(describing: records.first))")
            return
        }
        #expect(r.deathYear == 1901)
        #expect(r.deathDate == "1901")
        #expect(r.memorialID == nil)
    }

    @Test func cremationFactMapsToBurialWithYear() throws {
        let data = envelope(
            factType: "http://gedcomx.org/Cremation", date: "1955",
            collection: "England, Cremation Indexes, 1885-2005")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict, recordType: .burial))
        guard case .burial(let r) = records.first else {
            Issue.record("Expected .burial, got \(String(describing: records.first))")
            return
        }
        #expect(r.deathYear == 1955)
    }

    @Test func fagCollectionBurialKeepsNilDatesForBridge() throws {
        // The FS→FindAGrave bridge fires on `deathYear == nil` +
        // memorialID — a FAG-collection burial must keep its nils even
        // when the search response carries a date, or inscription mining
        // permanently stops for bridge records.
        let data = envelope(
            factType: "http://gedcomx.org/Burial", date: "1944",
            collection: "Find A Grave Index",
            extRecordID: "271612558")
        let records = try FamilySearchSource.parseSearchResponse(
            data: data, query: query(strictness: .strict, recordType: .burial))
        guard case .burial(let r) = records.first else {
            Issue.record("Expected .burial, got \(String(describing: records.first))")
            return
        }
        #expect(r.memorialID == 271612558)
        #expect(r.deathYear == nil)
        #expect(r.deathDate == nil)
    }

    // MARK: - Change 3: honesty envelope (total capture + truncation rule)

    @Test func parserSurfacesEnvelopeTotalAndEntryCount() throws {
        // The endpoint's top-level "results" is the server's claimed total
        // hit count — decoded since first cut but discarded until Change 3.
        let json = """
        {
          "results": 2318797,
          "entries": [{
            "content": {
              "gedcomx": {
                "persons": [{
                  "id": "p0",
                  "names": [{"nameForms": [{
                    "fullText": "Kenneth Cauldwell",
                    "parts": [
                      {"type": "http://gedcomx.org/Given", "value": "Kenneth"},
                      {"type": "http://gedcomx.org/Surname", "value": "Cauldwell"}
                    ]}]}],
                  "facts": [{"type": "http://gedcomx.org/Death",
                             "date": {"original": "2007", "formal": "+2007"}}]
                }],
                "sourceDescriptions": [{"about": "ark:/61903/c", "titles": [{"value": "T"}]}]
              }
            }
          }]
        }
        """
        let parsed = try FamilySearchSource.parseSearchResponseWithTotal(
            data: Data(json.utf8), query: query(strictness: .strict))
        #expect(parsed.totalAvailable == 2_318_797)
        #expect(parsed.entryCount == 1)
        #expect(parsed.records.count == 1)
    }

    @Test func truncationRule() {
        // Server claims more hits than the page carries → truncated.
        #expect(FamilySearchSource.isTruncated(entryCount: 100, totalAvailable: 2_318_797))
        #expect(FamilySearchSource.isTruncated(entryCount: 20, totalAvailable: 21))
        // Total accounted for on this page → complete.
        #expect(!FamilySearchSource.isTruncated(entryCount: 80, totalAvailable: 80))
        #expect(!FamilySearchSource.isTruncated(entryCount: 0, totalAvailable: 0))
        // No claimed total: a full page is a suspected partial; a short
        // page is complete.
        #expect(FamilySearchSource.isTruncated(entryCount: FamilySearchSource.pageSize, totalAvailable: nil))
        #expect(!FamilySearchSource.isTruncated(entryCount: 3, totalAvailable: nil))
    }
}
