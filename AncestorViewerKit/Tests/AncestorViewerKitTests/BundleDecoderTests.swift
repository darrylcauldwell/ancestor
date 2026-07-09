import Testing
import Foundation
@testable import AncestorViewerKit

// The bundle is the offline stand-in for the CloudKit zone (same UUIDs,
// same schema — PUBLISHER_SPEC decision #3), so decoding one through the
// cache + builder exercises the full viewer pipeline without a network.
struct BundleDecoderTests {

    private let manifestJSON = Data(#"""
        {"schemaVersion": 1, "generation": 3, "rootPerson": "P1",
         "personCount": 2, "relationshipCount": 1,
         "publishedAtISO": "2026-07-08T06:58:00Z"}
        """#.utf8)

    private let peopleJSON = Data(#"""
        [{"id": "P1", "schemaVersion": 1, "displayName": "Ernest Cauldwell",
          "givenName": "Ernest", "familyName": "Cauldwell", "genderRaw": "male",
          "birth": {"original": "1887", "earliest": 1887, "latest": 1887,
                    "qualifierRaw": "yearOnly", "isApproximate": false},
          "birthPlace": "Crich, Derbyshire",
          "death": null, "deathPlace": null,
          "bioText": "Ernest was a framework knitter.",
          "citationsJSON": "[]", "badgesJSON": "{}",
          "isRedacted": false, "isProvisional": false},
         {"id": "P2", "schemaVersion": 1, "displayName": "Mary Cauldwell",
          "givenName": null, "familyName": null, "genderRaw": null,
          "birth": null, "birthPlace": null, "death": null, "deathPlace": null,
          "bioText": "", "citationsJSON": "[]", "badgesJSON": "{}",
          "isRedacted": true, "isProvisional": false}]
        """#.utf8)

    private let relationshipsJSON = Data(#"""
        [{"id": "5AA8B380-0000-0000-0000-000000000001", "schemaVersion": 1,
          "fromPerson": "P1", "toPerson": "P2", "typeRaw": "spouse",
          "roleRaw": null, "subtypeRaw": "unknown",
          "marriage": null, "marriageLocation": null, "divorce": null}]
        """#.utf8)

    private let eventsJSON = Data(#"""
        [{"id": "5AA8B380-0000-0000-0000-000000000002", "schemaVersion": 1,
          "person": "P1", "kindRaw": "census",
          "date": {"original": "1911", "earliest": 1911, "latest": 1911,
                   "qualifierRaw": "yearOnly", "isApproximate": false},
          "location": "Crich", "detailsJSON": null,
          "sourceURL": "https://www.freecen.org.uk/x"}]
        """#.utf8)

    private let mediaJSON = Data("[]".utf8)

    @Test func bundleDecodesAndFlattensNestedDates() throws {
        let (manifest, records) = try BundleDecoder.decode(
            manifestJSON: manifestJSON, peopleJSON: peopleJSON,
            relationshipsJSON: relationshipsJSON, eventsJSON: eventsJSON,
            mediaJSON: mediaJSON)
        #expect(manifest.generation == 3)
        #expect(records.count == 5) // manifest + 2 people + 1 rel + 1 event

        let person = records.compactMap { record -> PersonRow? in
            if case .person(let row) = record, row.id == "P1" { return row }
            return nil
        }.first
        #expect(person?.birthEarliest == 1887)
        #expect(person?.birthQualifierRaw == "yearOnly")
        #expect(person?.manifestID == manifest.id)
    }

    @Test func bundleRoundTripsThroughCacheAndBuilder() throws {
        let (manifest, records) = try BundleDecoder.decode(
            manifestJSON: manifestJSON, peopleJSON: peopleJSON,
            relationshipsJSON: relationshipsJSON, eventsJSON: eventsJSON,
            mediaJSON: mediaJSON)

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-bundle-\(UUID().uuidString).sqlite")
        let cache = try ViewerCache.open(at: cacheURL)
        try cache.apply(records: records, deletedRecordNames: [])

        let lineage = try cache.lineage(manifestID: manifest.id)
        let tree = SnapshotBuilder.build(
            manifest: lineage.manifest, persons: lineage.persons,
            relationships: lineage.relationships, events: lineage.events,
            media: lineage.media)

        #expect(tree.snapshot.profiles.count == 2)
        #expect(tree.snapshot.spousesOf("P1").map(\.id) == ["P2"])
        #expect(tree.annotations["P2"]?.isRedacted == true)
        #expect(tree.events["P1"]?.first?.type == .census)
        #expect(tree.manifest.personCount == 2)
        #expect(tree.schemaExceedsSupported == false)
    }
}
