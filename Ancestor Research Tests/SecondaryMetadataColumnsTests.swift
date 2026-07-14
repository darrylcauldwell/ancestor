import Testing
import Foundation
import GRDB
@testable import Ancestor_Research
import AncestorKit

/// FAMILYSEARCH_READ_LEG_PLAN #Change7 — the secondary-metadata data-model
/// commits: RecordCommon's placeARK / collectionCompleteness /
/// volatilityScore columns (§12.4), the v43 evidence external-ARK
/// migration (§17.1), and FS promoting completeness + place ARK to
/// first-class fields.
struct SecondaryMetadataColumnsTests {

    // MARK: - RecordCommon additive Codable (old rows must still decode)

    @Test func recordCommonDecodesLegacyJSONWithoutNewKeys() throws {
        // A pre-#Change7 evidence_records.record_json blob has none of the
        // three new keys. Optional + synthesized Codable → they decode nil.
        let legacy = #"""
        {"id":"p_1","sourceID":"familysearch","name":"Kenneth Cauldwell",
         "surname":"Cauldwell","givenName":"Kenneth","rawFields":{}}
        """#
        let common = try JSONDecoder().decode(RecordCommon.self, from: Data(legacy.utf8))
        #expect(common.id == "p_1")
        #expect(common.placeARK == nil)
        #expect(common.collectionCompleteness == nil)
        #expect(common.volatilityScore == nil)
    }

    @Test func recordCommonRoundTripsNewFields() throws {
        let common = RecordCommon(
            id: "r1", sourceID: "familysearch", rawFields: [:],
            placeARK: "ark:/61903/2:1:PLACE", collectionCompleteness: 0.94,
            volatilityScore: 0.2)
        let data = try JSONEncoder().encode(common)
        let decoded = try JSONDecoder().decode(RecordCommon.self, from: data)
        #expect(decoded.placeARK == "ark:/61903/2:1:PLACE")
        #expect(decoded.collectionCompleteness == 0.94)
        #expect(decoded.volatilityScore == 0.2)
    }

    // MARK: - v43 migration

    @Test func v43AddsEvidenceExternalIdColumns() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        let dbQueue = try DatabaseQueue(path: path)
        try ProjectDatabase.makeMigrator().migrate(dbQueue)
        let applied = try dbQueue.read { db in
            try ProjectDatabase.makeMigrator().appliedIdentifiers(db)
        }
        #expect(applied.contains("v43_evidence_external_ids"))
        // Columns exist and accept bare ARK path segments.
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO evidence_records
                  (id, profile_id, source_id, source_record_id, record_type,
                   verdict, record_json, scored_at, external_persona_id, external_record_id)
                VALUES ('e1','p1','familysearch','r1','death','fact','{}',?,
                        'ark:/61903/1:1:6PPQ-DCZV','ark:/61903/4:1:REC')
                """, arguments: [Date()])
            let (persona, record) = try Row.fetchOne(db, sql: """
                SELECT external_persona_id, external_record_id FROM evidence_records WHERE id='e1'
                """).map { ($0["external_persona_id"] as String?, $0["external_record_id"] as String?) }!
            #expect(persona == "ark:/61903/1:1:6PPQ-DCZV")
            #expect(record == "ark:/61903/4:1:REC")
        }
    }

    // MARK: - FS promotes completeness + place ARK

    @Test func familySearchPromotesCollectionCompletenessAndPlaceARK() throws {
        let json = """
        {
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
                  "facts": [{
                    "type": "http://gedcomx.org/Death",
                    "date": {"original": "2007", "formal": "+2007"},
                    "place": {
                      "original": "Derbyshire, England",
                      "normalized": [{"description": "https://www.familysearch.org/ark:/61903/2:1:M9V7-PLACE"}]
                    }
                  }]
                }],
                "sourceDescriptions": [{
                  "about": "ark:/61903/coll-1",
                  "titles": [{"value": "England Deaths"}],
                  "coverage": [{"completeness": 0.94}]
                }]
              }
            }
          }]
        }
        """
        let q = RecordQuery(
            surname: "Cauldwell", givenName: "Kenneth", recordType: .death,
            yearFrom: 1919, yearTo: 2017, gender: .male, region: nil,
            sourceParams: .generic, strictness: .strict)
        let records = try FamilySearchSource.parseSearchResponse(data: Data(json.utf8), query: q)
        let common = try #require(records.first?.common)
        #expect(common.collectionCompleteness == 0.94)
        // Bare ARK path segment only — the https:// prefix is stripped.
        #expect(common.placeARK == "ark:/61903/2:1:M9V7-PLACE")
    }

    @Test func familySearchPlaceARKNilWhenNoNormalizedARK() throws {
        let json = """
        {
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
                             "date": {"original": "2007", "formal": "+2007"},
                             "place": {"original": "Derbyshire, England"}}]
                }],
                "sourceDescriptions": [{"about": "ark:/61903/c", "titles": [{"value": "T"}]}]
              }
            }
          }]
        }
        """
        let q = RecordQuery(
            surname: "Cauldwell", givenName: "Kenneth", recordType: .death,
            yearFrom: 1919, yearTo: 2017, gender: .male, region: nil,
            sourceParams: .generic, strictness: .strict)
        let records = try FamilySearchSource.parseSearchResponse(data: Data(json.utf8), query: q)
        let common = try #require(records.first?.common)
        #expect(common.placeARK == nil)
        #expect(common.collectionCompleteness == nil)
    }
}
