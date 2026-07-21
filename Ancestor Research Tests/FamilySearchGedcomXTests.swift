import Testing
import Foundation
@testable import Ancestor_Research

/// FamilySearch client — Slice 2. Proves the `FS*` GEDCOM X model decodes both
/// envelope shapes and the load-bearing edge cases (the `identifiers` map,
/// `Field`/`FieldValue` original-vs-interpreted, ms timestamps,
/// `ChildAndParentsRelationship`, the error body). Fixtures mirror the real
/// shapes in the official SDK fixtures (`fs-php-lite .../person.json`) and the
/// documented Atom search feed.
struct FamilySearchGedcomXTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Tree read (application/x-fs-v1+json → FSGedcomx)

    private let treeReadJSON = """
    {
      "persons": [{
        "sortKey": "0000000000",
        "living": false,
        "identifiers": { "http://gedcomx.org/Persistent": [ "https://sandbox.familysearch.org/ark:/61903/4:1:L5C2-WYC" ] },
        "gender": { "type": "http://gedcomx.org/Male" },
        "names": [{ "type": "http://gedcomx.org/BirthName", "preferred": true,
          "nameForms": [{ "fullText": "Ebenezer Clark", "parts": [
            { "type": "http://gedcomx.org/Given", "value": "Ebenezer" },
            { "type": "http://gedcomx.org/Surname", "value": "Clark" } ] }] }],
        "facts": [{ "type": "http://gedcomx.org/Birth",
          "date": { "original": "29 Nov 1651", "formal": "+1651-11-29",
            "normalized": [ { "lang": "en-US", "value": "29 November 1651" } ] },
          "place": { "original": "NEW HAVEN,NEW HAVEN,CONN", "description": "#1740247784",
            "normalized": [ { "value": "New Haven, New Haven, Connecticut, United States" } ] } }]
      }],
      "sourceDescriptions": [{
        "id": "SD-L5C2-WYC", "resourceType": "http://gedcomx.org/Person", "about": "#L5C2-WYC",
        "citations": [{ "lang": "en", "value": "\\"Family Tree,\\" database, FamilySearch" }],
        "titles": [{ "value": "Ebenezer Clark" }],
        "identifiers": { "http://gedcomx.org/Persistent": [ "https://sandbox.familysearch.org/ark:/61903/4:1:L5C2-WYC" ] },
        "modified": 1470770475000, "version": "136900632758820000"
      }]
    }
    """

    @Test func decodesTreePersonReadEnvelope() throws {
        let gx = try decode(FSGedcomx.self, treeReadJSON)
        let person = try #require(gx.persons?.first)
        #expect(person.sortKey == "0000000000")
        #expect(person.living == false)
        #expect(person.gender?.type == "http://gedcomx.org/Male")
        let form = try #require(person.names?.first?.nameForms?.first)
        #expect(form.fullText == "Ebenezer Clark")
        #expect(form.parts?.first(where: { $0.type == "http://gedcomx.org/Given" })?.value == "Ebenezer")
        #expect(form.parts?.first(where: { $0.type == "http://gedcomx.org/Surname" })?.value == "Clark")
    }

    @Test func decodesIdentifiersMapAndPersistentArk() throws {
        let gx = try decode(FSGedcomx.self, treeReadJSON)
        let ids = try #require(gx.persons?.first?.identifiers)
        #expect(ids.persistent == "https://sandbox.familysearch.org/ark:/61903/4:1:L5C2-WYC")
        #expect(ids["http://gedcomx.org/Persistent"].count == 1)
        #expect(ids["http://gedcomx.org/Nonexistent"].isEmpty)
    }

    @Test func decodesFactDateAndPlaceWithNormalized() throws {
        let gx = try decode(FSGedcomx.self, treeReadJSON)
        let birth = try #require(gx.persons?.first?.facts?.first)
        #expect(birth.type == "http://gedcomx.org/Birth")
        #expect(birth.date?.formal == "+1651-11-29")
        #expect(birth.date?.normalized?.first?.value == "29 November 1651")
        #expect(birth.place?.description == "#1740247784")
        #expect(birth.place?.normalized?.first?.value == "New Haven, New Haven, Connecticut, United States")
    }

    @Test func decodesSourceDescriptionWithMillisTimestampAndVersion() throws {
        let gx = try decode(FSGedcomx.self, treeReadJSON)
        let sd = try #require(gx.sourceDescriptions?.first)
        #expect(sd.resourceType == "http://gedcomx.org/Person")
        #expect(sd.modified == 1_470_770_475_000)          // ms since epoch (Int64)
        #expect(sd.version == "136900632758820000")        // a String, not a number
        #expect(sd.titles?.first?.value == "Ebenezer Clark")
        #expect(sd.citations?.first?.value?.isEmpty == false)
    }

    // MARK: Search feed (application/x-gedcomx-atom+json → RecordsSearchFeed)

    @Test func decodesRecordsSearchFeedWithScoreAndFields() throws {
        let json = """
        {
          "results": 2318797,
          "index": 0,
          "entries": [{
            "id": "1:1:XXXX", "score": 12.34, "confidence": 5.0,
            "content": { "gedcomx": {
              "persons": [{
                "extracted": true, "principal": true,
                "names": [{ "nameForms": [{ "parts": [
                  { "type": "http://gedcomx.org/Given", "value": "Ernest" },
                  { "type": "http://gedcomx.org/Surname", "value": "Cauldwell" } ] }] }],
                "gender": { "type": "http://gedcomx.org/Male" },
                "facts": [{ "type": "http://gedcomx.org/Birth", "date": { "original": "1887" },
                  "fields": [{ "type": "http://gedcomx.org/Age", "values": [
                    { "type": "http://gedcomx.org/Original", "text": "34" },
                    { "type": "http://gedcomx.org/Interpreted", "text": "34", "datatype": "http://www.w3.org/2001/XMLSchema#int" } ] }] }]
              }],
              "sourceDescriptions": [{ "about": "ark:/61903/1:1:XXXX",
                "titles": [{ "value": "England Births 1887" }],
                "coverage": [{ "completeness": 0.95 }] }]
            } },
            "searchInfo": { "totalHits": 2318797, "closeHits": 12 }
          }]
        }
        """
        let feed = try decode(RecordsSearchFeed.self, json)
        #expect(feed.results == 2_318_797)          // total dwarfs the returned page → truncation signal
        #expect(feed.index == 0)
        let entry = try #require(feed.entries?.first)
        #expect(entry.score == 12.34)
        #expect(entry.searchInfo?.totalHits == 2_318_797)
        let persona = try #require(entry.content?.gedcomx?.persons?.first)
        #expect(persona.extracted == true)
        #expect(persona.principal == true)
        let ageField = try #require(persona.facts?.first?.fields?.first)
        #expect(ageField.type == "http://gedcomx.org/Age")
        #expect(ageField.values?.first(where: { $0.type == "http://gedcomx.org/Original" })?.text == "34")
        let interpreted = try #require(ageField.values?.first(where: { $0.type == "http://gedcomx.org/Interpreted" }))
        #expect(interpreted.datatype == "http://www.w3.org/2001/XMLSchema#int")
        let sd = try #require(entry.content?.gedcomx?.sourceDescriptions?.first)
        #expect(sd.about == "ark:/61903/1:1:XXXX")
        #expect(sd.coverage?.first?.completeness == 0.95)
    }

    @Test func decodesMatchesFeedWithMatchInfoCollection() throws {
        let json = """
        {
          "entries": [{
            "score": 9.0,
            "matchInfo": [{ "collection": "https://familysearch.org/platform/collections/records",
                            "status": "http://familysearch.org/v1/Pending" }],
            "content": { "gedcomx": { "persons": [{ "names": [{ "nameForms": [{ "fullText": "Ernest Cauldwell" }] }] }] } }
          }]
        }
        """
        let feed = try decode(RecordsSearchFeed.self, json)
        let match = try #require(feed.entries?.first?.matchInfo?.first)
        #expect(match.collection == "https://familysearch.org/platform/collections/records")
        #expect(match.status == "http://familysearch.org/v1/Pending")
    }

    // MARK: Relationships + errors

    @Test func decodesChildAndParentsRelationshipTriad() throws {
        let json = """
        {
          "persons": [{ "id": "C" }],
          "childAndParentsRelationships": [{
            "father": { "resource": "https://familysearch.org/platform/tree/persons/FATHER" },
            "mother": { "resourceId": "MOTHER" },
            "child": { "resourceId": "C" }
          }]
        }
        """
        let gx = try decode(FSGedcomx.self, json)
        let triad = try #require(gx.childAndParentsRelationships?.first)
        #expect(triad.father?.resource == "https://familysearch.org/platform/tree/persons/FATHER")
        #expect(triad.mother?.resourceId == "MOTHER")
        #expect(triad.child?.resourceId == "C")
    }

    @Test func decodesErrorBody() throws {
        // The exact failure the guessed free-text probe hit — modelled, not misread.
        let json = """
        { "errors": [ { "code": 400, "label": "Bad Request",
                        "message": "the q query parameter is no longer supported" } ] }
        """
        let gx = try decode(FSGedcomx.self, json)
        let error = try #require(gx.errors?.first)
        #expect(error.code == 400)
        #expect(error.message?.contains("no longer supported") == true)
    }
}
