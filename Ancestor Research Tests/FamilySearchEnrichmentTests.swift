import Testing
import Foundation
import AncestorKit
@testable import Ancestor_Research

/// FamilySearch client — Slice 6. The enrichment leg: record hints → lead-shaped
/// items (§18 confidence orders only), the ARK helper, and the link-only
/// memories pointer decode. Serialized + MainActor for the mock-client flow and
/// the actor's MainActor-isolated init.
@Suite(.serialized)
@MainActor
struct FamilySearchEnrichmentTests {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FSMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: parseHints (pure)

    @Test func parseHintsExtractsArkCollectionConfidenceAndFacts() throws {
        let feed = try JSONDecoder().decode(RecordsSearchFeed.self, from: Data(#"""
        { "entries": [ {
            "score": 8.5,
            "matchInfo": [ { "collection": "https://familysearch.org/platform/collections/records", "status": "http://familysearch.org/v1/Pending" } ],
            "content": { "gedcomx": {
              "persons": [ { "names": [ { "nameForms": [ { "fullText": "Ernest Cauldwell" } ] } ],
                "facts": [ { "type": "http://gedcomx.org/Birth", "date": { "formal": "+1887" },
                             "place": { "original": "Derbyshire, England" } } ] } ],
              "sourceDescriptions": [ { "about": "https://sandbox.familysearch.org/ark:/61903/1:1:ABC",
                                        "titles": [ { "value": "England Births 1887" } ] } ]
            } } } ] }
        """#.utf8))
        let hints = FamilySearchEnrichmentService.parseHints(feed, treePersonID: "LZ8X-9AB")
        let hint = try #require(hints.first)
        #expect(hint.ark == "ark:/61903/1:1:ABC")             // bare path, not full URL
        #expect(hint.collectionTitle == "England Births 1887")
        #expect(hint.matchConfidence == 8.5)
        #expect(hint.name == "Ernest Cauldwell")
        #expect(hint.year == 1887)
        #expect(hint.place == "Derbyshire, England")
        #expect(hint.recordType == "Birth")
        #expect(hint.treePersonID == "LZ8X-9AB")
    }

    @Test func parseHintsSkipsIdentityLessEntries() throws {
        let feed = try JSONDecoder().decode(RecordsSearchFeed.self, from: Data(
            #"{ "entries": [ { "score": 1.0, "content": { "gedcomx": { "persons": [ { } ] } } } ] }"#.utf8))
        #expect(FamilySearchEnrichmentService.parseHints(feed, treePersonID: "X").isEmpty)
    }

    @Test func bareArkExtraction() {
        #expect(FamilySearchEnrichmentService.bareArk(from: "https://familysearch.org/ark:/61903/1:1:ABC") == "ark:/61903/1:1:ABC")
        #expect(FamilySearchEnrichmentService.bareArk(from: "#1740247784") == nil)
        #expect(FamilySearchEnrichmentService.bareArk(from: nil) == nil)
    }

    // MARK: §18 ordering (mock-client flow)

    @Test func recordHintsOrderByConfidenceHighestFirst() async throws {
        FSMockURLProtocol.reset()
        // 1) tree search → one matching tree person.
        FSMockURLProtocol.enqueue(status: 200, body: Data(
            #"{ "entries": [ { "content": { "gedcomx": { "persons": [ { "id": "L5C2-WYC" } ] } } } ] }"#.utf8))
        // 2) that person's record hints → two, out of confidence order.
        FSMockURLProtocol.enqueue(status: 200, body: Data(#"""
        { "entries": [
          { "score": 3.0, "content": { "gedcomx": { "persons": [ { "names": [ { "nameForms": [ { "fullText": "Low Match" } ] } ] } ],
              "sourceDescriptions": [ { "about": "ark:/61903/1:1:LOW", "titles": [ { "value": "C" } ] } ] } } },
          { "score": 9.0, "content": { "gedcomx": { "persons": [ { "names": [ { "nameForms": [ { "fullText": "High Match" } ] } ] } ],
              "sourceDescriptions": [ { "about": "ark:/61903/1:1:HIGH", "titles": [ { "value": "C" } ] } ] } } }
        ] }
        """#.utf8))
        let client = FamilySearchClient(environment: .beta, tokenSource: EnrichStubToken(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        let service = FamilySearchEnrichmentService(client: client, environment: .beta)
        let hints = await service.recordHints(surname: "Cauldwell", givenName: "Ernest", birthYear: 1887, deathYear: nil)
        #expect(hints.count == 2)
        #expect(hints.first?.name == "High Match")   // §18: confidence orders the list
        #expect(hints.last?.name == "Low Match")
    }

    @Test func recordHintsEmptyWhenNotInSharedTree() async throws {
        FSMockURLProtocol.reset()
        FSMockURLProtocol.enqueue(status: 204)   // tree search: no matching tree person
        let client = FamilySearchClient(environment: .beta, tokenSource: EnrichStubToken(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        let service = FamilySearchEnrichmentService(client: client, environment: .beta)
        let hints = await service.recordHints(surname: "Nonesuch", givenName: nil, birthYear: nil, deathYear: nil)
        #expect(hints.isEmpty)
    }

    // MARK: memories pointer decode (link-only)

    @Test func memoriesEnvelopeDecodesPointerFields() throws {
        let env = try JSONDecoder().decode(FamilySearchMemoriesEnvelope.self, from: Data(#"""
        { "sourceDescriptions": [ { "about": "https://familysearch.org/ark:/61903/3:1:MEM",
                                     "titles": [ { "value": "Portrait" } ],
                                     "links": { "image": { "href": "https://familysearch.org/img/MEM" } } } ] }
        """#.utf8))
        let memory = try #require(env.sourceDescriptions?.first)
        #expect(memory.about == "https://familysearch.org/ark:/61903/3:1:MEM")
        #expect(memory.titles?.first?.value == "Portrait")
        #expect(memory.links?["image"]?.href == "https://familysearch.org/img/MEM")
    }

    // MARK: S6b — hints as scorer-routed SourceRecords

    private func recordQuery(surname: String = "Cauldwell") -> RecordQuery {
        RecordQuery(surname: surname, givenName: nil, recordType: .birth,
                    yearFrom: nil, yearTo: nil, gender: nil, region: nil,
                    sourceParams: .generic, strictness: .variant)
    }

    @Test func parseSearchFeedStampsFsMatchScoreAndKeepsPersonaIdAsDedupKey() throws {
        let feed = try JSONDecoder().decode(RecordsSearchFeed.self, from: Data(#"""
        { "entries": [ { "score": 7.5, "content": { "gedcomx": {
            "persons": [ { "id": "p_1", "names": [ { "nameForms": [ { "parts": [
                { "type": "http://gedcomx.org/Surname", "value": "Cauldwell" } ] } ] } ],
              "facts": [ { "type": "http://gedcomx.org/Birth", "date": { "formal": "+1887" } } ] } ],
            "sourceDescriptions": [ { "titles": [ { "value": "Births" } ] } ]
        } } } ] }
        """#.utf8))
        let record = try #require(FamilySearchSource.parseSearchFeed(feed, query: recordQuery()).records.first)
        #expect(record.rawFields["fsMatchScore"] == "7.5")
        #expect(record.id == "p_1")   // persona id = the "<profileID>|id" dedup key vs records search
    }

    @Test func parseSearchFeedOmitsFsMatchScoreWhenEntryHasNone() throws {
        let feed = try JSONDecoder().decode(RecordsSearchFeed.self, from: Data(#"""
        { "entries": [ { "content": { "gedcomx": {
            "persons": [ { "id": "p_2", "names": [ { "nameForms": [ { "parts": [
                { "type": "http://gedcomx.org/Surname", "value": "Cauldwell" } ] } ] } ],
              "facts": [ { "type": "http://gedcomx.org/Birth" } ] } ] } } } ] }
        """#.utf8))
        let record = try #require(FamilySearchSource.parseSearchFeed(feed, query: recordQuery()).records.first)
        #expect(record.rawFields["fsMatchScore"] == nil)   // absent, not the string "nil"
    }

    @Test func recordHintsAsSourceRecordsCarryScoreProvenanceAndPersonaId() async throws {
        FSMockURLProtocol.reset()
        // 1) tree search → one matching tree person.
        FSMockURLProtocol.enqueue(status: 200, body: Data(
            #"{ "entries": [ { "content": { "gedcomx": { "persons": [ { "id": "L5C2-WYC" } ] } } } ] }"#.utf8))
        // 2) that person's record hints → one full record persona with a score.
        FSMockURLProtocol.enqueue(status: 200, body: Data(#"""
        { "entries": [ { "score": 9.0, "content": { "gedcomx": {
            "persons": [ { "id": "p_hint", "names": [ { "nameForms": [ { "parts": [
                { "type": "http://gedcomx.org/Given", "value": "Ernest" },
                { "type": "http://gedcomx.org/Surname", "value": "Cauldwell" } ] } ] } ],
              "facts": [ { "type": "http://gedcomx.org/Birth", "date": { "formal": "+1887" },
                           "place": { "original": "Derbyshire" } } ] } ],
            "sourceDescriptions": [ { "about": "ark:/61903/1:1:XYZ", "titles": [ { "value": "Births" } ] } ]
        } } } ] }
        """#.utf8))
        let client = FamilySearchClient(environment: .beta, tokenSource: EnrichStubToken(bearer: "T"),
                                        session: mockSession(), sleeper: { _ in })
        let service = FamilySearchEnrichmentService(client: client, environment: .beta)
        let records = await service.recordHintsAsSourceRecords(
            surname: "Cauldwell", givenName: "Ernest", birthYear: 1887, deathYear: nil)
        let record = try #require(records.first)
        #expect(record.id == "p_hint")                                  // dedup key vs records search
        #expect(record.rawFields["fsMatchScore"] == "9.0")              // §18 signal, stored not gated
        #expect(record.rawFields["fsTreePersonID"] == "L5C2-WYC")       // provenance
        #expect(record.recordType == .birth)                           // full typed record, not a lossy hint
        #expect(record.common.detailURL == "https://www.familysearch.org/ark:/61903/1:1:p_hint")
    }
}

private struct EnrichStubToken: FamilySearchTokenSource {
    let bearer: String?
    func currentBearer() async -> String? { bearer }
    func refreshBearer() async -> String? { nil }
}
