import Testing
import Foundation
@testable import AncestorViewerKit

struct ViewerCacheTests {

    private func makeCache() throws -> ViewerCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-cache-\(UUID().uuidString).sqlite")
        return try ViewerCache.open(at: url)
    }

    private var fixtureRecords: [MappedRecord] {
        [
            .manifest(ManifestRow(id: "M1", generation: 3, rootPerson: "P1",
                                  personCount: 2, relationshipCount: 1,
                                  publishedAtISO: "2026-07-08T06:58:00Z")),
            .person(PersonRow(id: "P1", manifestID: "M1", displayName: "Ernest Cauldwell",
                              givenName: "Ernest", familyName: "Cauldwell",
                              birthOriginal: "1887", birthEarliest: 1887, birthLatest: 1887,
                              birthQualifierRaw: "yearOnly", birthIsApproximate: false)),
            .person(PersonRow(id: "P2", manifestID: "M1", displayName: "Mary Cauldwell",
                              isRedacted: true)),
            .relationship(RelationshipRow(id: "R1", fromPersonID: "P1", toPersonID: "P2",
                                          typeRaw: "spouse")),
            .lifeEvent(EventRow(id: "E1", personID: "P1", kindRaw: "census",
                                dateEarliest: 1911, dateLatest: 1911)),
            .media(MediaRow(id: "MD1", personID: "P1", kind: "portrait",
                            relativePath: "photos/e.jpg"))
        ]
    }

    @Test func applyThenReadLineageRoundTrips() throws {
        let cache = try makeCache()
        try cache.apply(records: fixtureRecords, deletedRecordNames: [])

        let lineage = try cache.lineage(manifestID: "M1")
        #expect(lineage.manifest.generation == 3)
        #expect(lineage.persons.count == 2)
        #expect(lineage.relationships.count == 1)
        #expect(lineage.events.count == 1)
        #expect(lineage.media.count == 1)
        #expect(lineage.persons.first { $0.id == "P2" }?.isRedacted == true)
    }

    @Test func reapplyUpdatesInPlace() throws {
        let cache = try makeCache()
        try cache.apply(records: fixtureRecords, deletedRecordNames: [])
        var updated = PersonRow(id: "P1", manifestID: "M1", displayName: "Ernest Cauldwell",
                                givenName: "Ernest", familyName: "Cauldwell")
        updated.bioText = "Updated bio."
        try cache.apply(records: [.person(updated)], deletedRecordNames: [])

        let lineage = try cache.lineage(manifestID: "M1")
        #expect(lineage.persons.count == 2)
        #expect(lineage.persons.first { $0.id == "P1" }?.bioText == "Updated bio.")
    }

    @Test func tombstonesDeleteByRecordNameConvention() throws {
        let cache = try makeCache()
        try cache.apply(records: fixtureRecords, deletedRecordNames: [])
        try cache.apply(records: [], deletedRecordNames: [
            "E1:publishedLifeEvents",
            "cloudkit.share",              // ignored — no table suffix
            "X9:publishedUnknownTable"     // ignored — unknown table
        ])
        let lineage = try cache.lineage(manifestID: "M1")
        #expect(lineage.events.isEmpty)
        #expect(lineage.persons.count == 2)
    }

    @Test func manifestScopingIsolatesLineages() throws {
        let cache = try makeCache()
        try cache.apply(records: fixtureRecords + [
            .manifest(ManifestRow(id: "M2", generation: 1)),
            .person(PersonRow(id: "Q1", manifestID: "M2", displayName: "Other Tree Person")),
            .relationship(RelationshipRow(id: "R2", fromPersonID: "Q1", toPersonID: "P1",
                                          typeRaw: "spouse"))
        ], deletedRecordNames: [])

        let m1 = try cache.lineage(manifestID: "M1")
        #expect(m1.persons.map(\.id).sorted() == ["P1", "P2"])
        #expect(m1.relationships.map(\.id) == ["R1"])

        let m2 = try cache.lineage(manifestID: "M2")
        #expect(m2.persons.map(\.id) == ["Q1"])
        #expect(m2.relationships.map(\.id) == ["R2"])
    }

    @Test func changeTokenRoundTripsAndWipeClearsEverything() throws {
        let cache = try makeCache()
        try cache.apply(records: fixtureRecords, deletedRecordNames: [])
        try cache.setChangeToken(Data([0xAB, 0xCD]))
        #expect(try cache.changeToken() == Data([0xAB, 0xCD]))

        try cache.wipe()
        #expect(try cache.changeToken() == nil)
        #expect(try cache.manifests().isEmpty)
    }

    @Test func missingManifestThrows() throws {
        let cache = try makeCache()
        #expect(throws: ViewerError.manifestNotFound("nope")) {
            try cache.lineage(manifestID: "nope")
        }
    }
}
